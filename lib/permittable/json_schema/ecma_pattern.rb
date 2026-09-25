require "strscan"

module Permittable
  module JsonSchema
    # Ruby Regexp source → an ECMA-262 `pattern` that compiles under the `u`
    # flag, which is how Ajv — the validator most clients reach for — builds
    # every pattern (`new RegExp(pattern, "u")`). Unicode mode is strict where
    # Ruby is forgiving: `\#`, `\-` and `\ ` are identity escapes Ruby
    # accepts and Unicode mode rejects, as are a bare `{`, a quantified
    # lookahead, and `\x7`. Other constructs compile but MEAN something else
    # there — `{,3}` is a literal without the flag, `&&` two ampersands — so
    # a source that merely compiles is not yet a translation.
    #
    # Hence one tokenizer pass rather than a scan and a few gsubs: it reads
    # escape pairs and character classes as units (so `\\A` stays a literal
    # backslash and A, and `*+` inside a class is two literals rather than a
    # possessive quantifier), and it is a whitelist — every token is either
    # rewritten into something both engines read identically or the whole
    # source is refused, and a refusal exports the regexp as
    # x-permittable-pattern. A construct nobody anticipated is therefore
    # refused rather than published, because a wrong pattern in published
    # docs is worse than a missing one.
    #
    # Refused on purpose, each for a reason ECMA-262 cannot carry:
    #   * Ruby's ^ and $, which anchor a LINE where ECMA-262 without the m
    #     flag anchors the whole string: /^\d{5}$/ accepts "evil\n12345" at
    #     runtime. \A and \z translate exactly.
    #   * \Z \h \K \R \G \e \g and the other Ruby-only escapes, and octal
    #     escapes, which Unicode mode rejects.
    #   * \b and \B outside a class. Ruby's word boundary counts a non-ASCII
    #     letter as a word character (its \w does not) and Unicode mode's is
    #     ASCII-only, so /\Aa\b/ rejects "a\u00e9" at runtime while ^a\b
    #     accepts it, and \B diverges the other way.
    #   * Backreferences. One to a group that took no part FAILS in Ruby and
    #     matches "" in ECMA-262 — /(a)?\1b/ rejects "b" at runtime and its
    #     translation would accept it — and \12 is a backreference or an
    #     octal escape depending on how many groups precede it.
    #   * Atomic, comment, quoted-name, flag, absence and conditional groups.
    #   * Possessive and stacked quantifiers, `{,n}`, and `{n}?`, which is
    #     "{n}, optionally" in Ruby and a lazy — so still exact — {n} in
    #     ECMA-262.
    #   * `\p{...}`, whose property names differ between the two.
    #   * Nested classes, POSIX brackets and `&&`; \S in a class beside
    #     anything but \s.
    #   * A repeated group name, a SyntaxError in Unicode mode before ES2025.
    module EcmaPattern
      module_function

      # Ruby's \s, as ECMA-262 escapes. Ruby's \s is ASCII-only; ECMA-262's
      # also matches NBSP, U+2028, U+FEFF and every other Unicode space, so
      # publishing \s verbatim would document a field accepting what the
      # server rejects. Spelled as escapes so a class can splice it in.
      SPACE = ' \t\n\v\f\r'.freeze

      # Escapes that name the same single character in both dialects, inside
      # a class or out. `\0` only on its own: followed by a digit it is octal
      # in Ruby and a SyntaxError in Unicode mode. `\x` only with two digits,
      # where Ruby also accepts one.
      CHARACTER_ESCAPE = /[tnrfv]|0(?!\d)|x\h{2}|u\h{4}|u\{\h{1,6}\}/

      # ECMA-262's syntax characters (and `/`): the only identity escapes
      # Unicode mode allows, and the way a literal one has to be spelled.
      SYNTAX_ESCAPE = %r{[\^$\\.*+?()\[\]{}|/]}

      # A group name both dialects accept. ASCII only; a non-ASCII name makes
      # the regexp encoding-fixed, which ecma_pattern refuses before this.
      GROUP_NAME = /[A-Za-z_]\w*/

      # nil when the source uses anything that cannot be carried faithfully.
      def translate(source)
        scanner = StringScanner.new(source)
        out = +""
        quantifiable = false # can the token just emitted take a quantifier?
        lookaround = [] # per open group: is it a lookaround?
        names = []
        until scanner.eos?
          if scanner.skip(/\\/)
            text, quantifiable = escape(scanner)
          elsif scanner.skip(/\[/)
            text = char_class(scanner)
            quantifiable = true
          elsif scanner.scan(/\(\?<(#{GROUP_NAME})>/o)
            # Unicode mode (before ES2025) rejects a repeated name; Ruby allows it.
            return nil if names.include?(scanner[1])

            names << scanner[1]
            lookaround << false
            text = scanner.matched
            quantifiable = false
          elsif scanner.scan(/\((?!\?)|\(\?(?:[:=!]|<[=!])/)
            lookaround << scanner.matched.end_with?("=", "!")
            text = scanner.matched
            quantifiable = false
          elsif scanner.skip(/\)/)
            return nil if lookaround.empty?

            text = ")"
            # A quantified lookaround is a SyntaxError in Unicode mode.
            quantifiable = !lookaround.pop
          elsif scanner.scan(/[*+?]|\{\d+(?:,\d*)?\}/)
            # A quantifier on a quantifier is possessive (`*+`) or nested
            # (`a{2}{3}`) in Ruby and a SyntaxError in ECMA-262; one on an
            # assertion or a group opening is a SyntaxError there too.
            return nil unless quantifiable

            text = scanner.matched
            if scanner.skip(/\?/)
              return nil if text.start_with?("{") && !text.include?(",")

              text += "?"
            end
            quantifiable = false
          elsif scanner.check(/\(\?|\{,\d+\}|[\^$]/)
            return nil
          elsif scanner.skip(/\./)
            # Ruby's dot stops only at \n; ECMA-262's (without the s flag)
            # also at \r, U+2028 and U+2029.
            text = '[^\n]'
            quantifiable = true
          elsif scanner.skip(/\|/)
            text = "|"
            quantifiable = false
          elsif scanner.scan(/[{}\]]/)
            # Literal in Ruby when they form no quantifier or class; bare,
            # each is a SyntaxError in Unicode mode.
            text = "\\#{scanner.matched}"
            quantifiable = true
          else
            text = scanner.getch
            quantifiable = true
          end
          return nil unless text

          out << text
        end
        out
      end

      # An escape outside a class, the backslash already consumed: the
      # translated text and whether a quantifier may follow it.
      def escape(scanner)
        if scanner.skip(/A/) then ["^", false]
        elsif scanner.skip(/z/) then ["$", false]
        elsif scanner.skip(/s/) then ["[#{SPACE}]", true]
        elsif scanner.skip(/S/) then ["[^#{SPACE}]", true]
        elsif scanner.scan(/[dDwW]/) then ["\\#{scanner.matched}", true]
        else [literal_escape(scanner), true]
        end
      end

      # The rest of a class, `[` already consumed. Ranges are only carried
      # between two single characters: `[\w-z]` is a RegexpError in Ruby on
      # either side of the hyphen (a class escape cannot end or start a
      # range), so that source can never reach this method as a real Regexp;
      # the refusal for it below is a defensive backstop, not something a
      # live disagreement between the two engines depends on. A hyphen right
      # after a just-closed range, `[a-c-e]`, is NOT a different range in
      # Unicode mode — both engines read it as the set {a, b, c, -, e},
      # rejecting "d" — so it is carried as a literal member, which may
      # itself reopen a range (`[a-z--x]`, Ruby's own reading of a second
      # hyphen after the first).
      def char_class(scanner)
        negated = scanner.skip(/\^/)
        # A leading ] is a literal in Ruby and ends an empty class in ECMA-262.
        return nil if scanner.check(/\]/)

        members = +""
        count = 0
        space = complement = false
        previous = nil # :char, :set (a class escape like \d) or :range
        until scanner.skip(/\]/)
          # A nested class or POSIX bracket, or an intersection.
          return nil if scanner.eos? || scanner.check(/\[|&&/)

          if previous == :range && scanner.check(/-(?!\])/)
            # A range cannot start from another range's own end: both
            # engines read this hyphen as an ordinary member, not a new
            # range operator. It may itself reopen a range on the next
            # iteration, exactly as Ruby reads a repeated hyphen.
            scanner.skip(/-/)
            members << "-"
            previous = :char
          elsif previous && scanner.check(/-(?!\])/)
            return nil unless previous == :char

            scanner.skip(/-/)
            # Checked again past the hyphen: `[$-&&%]` is an (empty)
            # intersection in Ruby and a class accepting "%" in ECMA-262.
            return nil if scanner.check(/\[|&&/)

            text, kind = class_atom(scanner)
            return nil unless kind == :char

            members << "-" << text
            previous = :range
          elsif scanner.skip(/\\S/)
            complement = true
            previous = :set
          else
            text, previous = class_atom(scanner)
            return nil unless text

            space ||= text == SPACE
            members << text
          end
          count += 1
        end
        return "[#{'^' if negated}#{members}]" unless complement

        # \S cannot be spliced in as members, but two classes containing it
        # can be written exactly. With \s beside it the class covers every
        # character whatever either escape means, so ECMA-262's wider \s is
        # harmless there — the `[\s\S]` any-character idiom. On its own it is
        # the complement of Ruby's \s. Beside anything else it is refused.
        return negated ? '[^\s\S]' : '[\s\S]' if space
        return nil unless count == 1

        negated ? "[#{SPACE}]" : "[^#{SPACE}]"
      end

      # One member of a class: its text and :char or :set.
      def class_atom(scanner)
        return [scanner.getch, :char] unless scanner.skip(/\\/)

        if scanner.skip(/s/) then [SPACE, :set]
        elsif scanner.scan(/[dDwW]/) then ["\\#{scanner.matched}", :set]
        # Both an escaped - and a backspace \b are valid in a Unicode-mode
        # class, and mean what they mean in Ruby.
        elsif scanner.scan(/[-b]/) then ["\\#{scanner.matched}", :char]
        else
          text = literal_escape(scanner)
          [text, :char] if text
        end
      end

      # An escape that names one character. A letter or digit not listed is
      # a Ruby-only escape (or octal) and refuses the translation; any other
      # character is an identity escape, which Unicode mode accepts only for
      # syntax characters — so those stay escaped and the rest (`\#`, `\-`
      # outside a class, `\ `, `\_`) are written bare, meaning the same thing.
      def literal_escape(scanner)
        if scanner.scan(CHARACTER_ESCAPE) || scanner.scan(SYNTAX_ESCAPE) then "\\#{scanner.matched}"
        elsif scanner.scan(/[^A-Za-z0-9]/m) then scanner.matched
        end
      end
    end
  end
end
