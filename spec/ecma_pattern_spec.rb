require "json"
require "open3"

# JSON Schema's `pattern` is an ECMA-262 regexp, and the validator most
# clients reach for — Ajv — compiles it as `new RegExp(pattern, "u")`. Unicode
# mode is strict: an identity escape like `\#` or `\-`, a bare `{`, a
# quantified lookahead — all legal in Ruby, all a SyntaxError there. Whether
# a translation compiles is a question only a real ECMA-262 engine can
# answer, and this is the kind of breakage that otherwise only shows up in
# someone else's toolchain (#47), so this spec asks node.
#
# Compiling is not enough on its own: `\s` compiled happily for years while
# accepting spaces the server rejects. So every translated regexp is also run
# against samples on both sides, and the two engines must agree.
RSpec.describe "Exported patterns under ECMA-262's u flag" do
  NODE_VERDICTS = <<~JS.freeze
    const cases = JSON.parse(require("fs").readFileSync(0, "utf8"));
    console.log(JSON.stringify(cases.map(({ pattern, samples }) => {
      try {
        const re = new RegExp(pattern, "u");
        return { results: samples.map((s) => re.test(s)) };
      } catch (e) {
        return { error: e.message };
      }
    })));
  JS

  # App-style regexps, each with samples chosen to sit on the edge the
  # translation has to get right. The redundant escapes are the point: apps
  # write them, Ruby accepts them, and Unicode mode does not.
  # rubocop:disable-next Style/RedundantRegexpEscape
  APP_REGEXPS = {
    /\A\d{5}\z/ => %w[12345 1234],
    /\A\d{3}\-\d{4}\z/ => %w[555-1234 5551234],
    /\A[\w\-]+\z/ => ["a-b_c", "a b"],
    /\A[\-+]?\d+\z/ => %w[-1 +1 1 --1],
    /\A\#[0-9a-f]{6}\z/ => %w[#00ff00 00ff00],
    /\A\ \z/ => [" ", "\u00a0"],
    /\A[^@\s]+@[^@\s]+\z/ => ["jo@example.com", "jo @example.com", "jo\u00a0x@example.com", "jo\u2028@example.com"],
    /\A\s*\z/ => ["", " \t\n\v\f\r", "\u00a0", "\ufeff", "\u2028", "\u3000"],
    /\A\S+\z/ => ["abc", "a\u00a0b", "a b"],
    /\A[\s\d]+\z/ => ["1 2", "1\u00a02"],
    /\A.+\z/ => ["abc", "a\rb", "a\u2028b", "a\u2029b", "a\nb"],
    /\A\\A\z/ => ["\\A", "A", ""],
    /\A\\z\z/ => ["\\z", "z"],
    /\A{\d}\z/ => ["{5}", "5"],
    /\A\$\d+(?:\.\d{2})?\z/ => ["$5", "$5.00", "5"],
    %r{\Ahttps?://\S+\z} => ["https://a.b/c", "https://a\u00a0b"],
    /\A(?:foo|bar)\z/ => %w[foo bar baz],
    /\A\u0041\x42\z/ => %w[AB aB],
    /\A(?<y>\d{2})-(?:ab)+\z/ => %w[12-abab 12-],
    /\A[a-z]{2,3}?\z/ => %w[ab abc a],
    /(?<=\$)\d+/ => %w[$5 5],
    /\A[a\]]\z/ => ["a", "]", "b"],
    /\A[a-c-]\z/ => %w[b - d],
    /\A\0\z/ => ["\0", "0"]
  }.freeze

  PRESET_SAMPLES = {
    email: ["jo@example.com", "jo#x+y@example.com", "jo@example", "jo @example.com", "@example.com"],
    uuid: %w[123e4567-e89b-12d3-a456-426614174000 123e4567e89b12d3a456426614174000],
    url: ["https://example.com/a?b#c", "http://example.com", "https://exa mple.com", "https://ex\u00a0ample.com",
          "ftp://example.com"],
    slug: %w[a-b-c a--b -a],
    hostname: %w[example.com ex-ample.co -example.com]
  }.freeze

  def self.node_path
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "node") }.find { |f| File.executable?(f) }
  end

  def verdicts_for(cases)
    out, err, status = Open3.capture3("node", "-e", NODE_VERDICTS, stdin_data: JSON.generate(cases))
    raise "node failed: #{err}" unless status.success?

    JSON.parse(out)
  end

  def exported(regexp_or_preset)
    klass = Class.new(FakeController) { include Permittable }
    klass.permit_params(:create) { optional :value, :string, format: regexp_or_preset }
    Permittable::JsonSchema.rule(klass.permit_rule_for(:create))["properties"]["value"]
  end

  # Compiles every pattern under test in ONE node process, so the spec costs
  # a single spawn however long the table grows.
  before(:context) do
    unless self.class.node_path
      skip "node is not on PATH, so exported patterns cannot be compiled as ECMA-262 (install Node.js to run this)"
    end

    fixture = JSON.parse(File.read(File.expand_path("fixtures/openapi.json", __dir__)))
    @cases = {}
    PRESET_SAMPLES.each { |name, samples| @cases["preset #{name.inspect}"] = [Permittable::FORMATS[name][:pattern], exported(name), samples] }
    APP_REGEXPS.each { |regexp, samples| @cases[regexp.inspect] = [regexp, exported(regexp), samples] }
    patterns_in(fixture).each_with_index { |pattern, i| @cases["golden fixture pattern ##{i}"] = [nil, { "pattern" => pattern }, []] }

    inputs = @cases.values.map { |_, schema, samples| { pattern: schema["pattern"].to_s, samples: samples } }
    @verdicts = @cases.keys.zip(verdicts_for(inputs)).to_h
  end

  def patterns_in(node)
    case node
    when Hash then node.flat_map { |key, value| key == "pattern" ? [value] : patterns_in(value) }
    when Array then node.flat_map { |value| patterns_in(value) }
    else []
    end
  end

  it "checks every preset" do
    expect(PRESET_SAMPLES.keys).to match_array(Permittable::FORMATS.keys)
  end

  it "exports every preset and every app-style regexp as a real pattern" do
    @cases.each do |label, (_, schema, _)|
      expect(schema).to have_key("pattern"), "#{label} exported #{schema.inspect}"
    end
  end

  it "exports only patterns that compile under the u flag" do
    @cases.each do |label, (_, schema, _)|
      expect(@verdicts[label]["error"]).to be_nil, "#{label} exported #{schema['pattern'].inspect}: #{@verdicts[label]['error']}"
    end
  end

  it "exports patterns that accept exactly what Ruby accepts on every sample" do
    @cases.each do |label, (regexp, schema, samples)|
      next unless regexp

      ruby = samples.map { |s| regexp.match?(s) }
      expect(@verdicts[label]["results"]).to eq(ruby),
                                             "#{label} → #{schema['pattern'].inspect} disagrees with Ruby on #{samples.inspect}: " \
                                             "Ruby #{ruby.inspect}, ECMA-262 #{@verdicts[label]['results'].inspect}"
    end
  end
end
