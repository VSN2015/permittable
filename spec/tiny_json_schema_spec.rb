# TinyJsonSchema is the conformance spec's measuring instrument, so a misreading
# there is a false verdict about the exporter. `pattern` is where it is easiest
# to misread: the document holds an ECMA-262 regexp, and Ruby compiles the same
# text with different anchors — `^abc$` accepts "abc\n" in Ruby and in no JSON
# Schema validator (#48).
#
# ecma_pattern_spec checks the instrument against node over every exported
# pattern. These cases pin the tokenizing edges without needing node: each is
# read the way ECMA-262 reads it without the m flag, which is how JSON Schema
# defines `pattern`.
#
# The table lives in a module rather than as a constant inside the describe
# block, which would define it at the top level.
module TinyJsonSchemaSpec
  # What the case proves => [pattern, accepted, rejected]. Patterns are
  # single-quoted so the backslashes are the ones the document holds.
  # rubocop:disable-next Style/WordArray -- the newlines are what is under test, and %W would hide them
  PATTERNS = {
    "anchors ^ and $ to the whole input, not a line" =>
      ['^abc$', ["abc"], ["abc\n", "\nabc", "x\nabc", "abc\nx"]],
    "leaves an unanchored pattern unanchored, as JSON Schema does" =>
      ['b', ["abc"], ["xyz"]],
    "reads anchors inside a group the same way" =>
      ['^(?:foo|bar)$', %w[foo bar], ["foo\n", "\nbar", "baz"]],
    "reads the exporter's translation of a dot, [^\\n], as spanning no line" =>
      ['^[^\n]+$', ["abc"], ["a\nb", "abc\n"]],
    "reads a class's leading ^ as negation" =>
      ['^[^a]$', ["b", "^"], ["a", "b\n"]],
    "reads a ^ later in a class as a literal" =>
      ['^[a^]$', ["a", "^"], ["b", "^\n"]],
    "reads a $ in a class as a literal" =>
      ['^[$]$', ["$"], ["z", "$\n"]],
    "keeps a class open past an escaped ]" =>
      ['^[\]^]$', ["]", "^"], ["a", "]\n"]],
    "reads an escaped ^ as a literal" =>
      ['^\^$', ["^"], ["", "^\n"]],
    "reads an escaped $ as a literal" =>
      ['^\$\d+$', ["$5"], ["5", "$5\n"]],
    "reads a $ after an escaped backslash as an anchor" =>
      ['^a\\\\$', ["a\\"], ["a", "a\\\n"]],
    "reads an escaped backslash and then an escaped $ as two literals" =>
      ['^a\\\\\$$', ["a\\$"], ["a\\", "a$", "a\\$\n"]]
  }.freeze
end

RSpec.describe TinyJsonSchema do
  describe "pattern" do
    TinyJsonSchemaSpec::PATTERNS.each do |label, (pattern, accepted, rejected)|
      it "#{label}: #{pattern}" do
        schema = { "type" => "string", "pattern" => pattern }
        misread = accepted.reject { |s| described_class.valid?(schema, s) } +
                  rejected.select { |s| described_class.valid?(schema, s) }
        expect(misread).to be_empty, "#{pattern.inspect} misread #{misread.inspect} " \
                                     "(should accept #{accepted.inspect}, reject #{rejected.inspect})"
      end
    end
  end
end
