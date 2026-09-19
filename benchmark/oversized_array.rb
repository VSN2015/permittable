# Measures what it costs to REJECT an array that is outside its `length:`.
#
# `length:` is a bound, not a report: an array outside it is refused by its
# first check, without its elements being cast, checked or reported on. This
# re-runs the measurement behind that claim, so the numbers in CHANGELOG.md
# can be checked rather than taken on trust.
#
#   bundle exec ruby benchmark/oversized_array.rb
require "bundler/setup"
require "benchmark"
require "json"
require "permittable"

COUNT = Integer(ENV.fetch("COUNT", 200_000))

SCALARS = Permittable::Contract.define do
  array :tags, of: :string, length: 0..10
end

HASHES = Permittable::Contract.define do
  array :line_items, length: 0..10 do
    required :sku, :string
    required :qty, :integer
  end
end

def report(label, contract, payload)
  result = nil
  seconds = Benchmark.realtime { result = contract.call(payload) }
  violations = result[:violations]
  body = JSON.generate(violations)
  puts format("%<label>-28s %<seconds>8.3f s  %<count>7d violation(s)  %<bytes>9d bytes of details",
              label: label, seconds: seconds, count: violations.length, bytes: body.bytesize)
end

puts "#{COUNT} elements against `length: 0..10`\n\n"
# Non-string elements: on an unbounded array every one of them is also an
# invalid_type violation, which is what used to make the body enormous.
report("array of scalars", SCALARS, tags: Array.new(COUNT) { |i| { "not" => i } })
report("array of hashes", HASHES, line_items: Array.new(COUNT) { {} })
