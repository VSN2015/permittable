module Permittable
  # A reusable field list — the same frozen data a contract's `fields` is,
  # without the contract around it. The answer to the duplication a growing
  # API produces: an `address` block wanted by three controllers, and an
  # `update` contract that is the `create` contract with everything relaxed.
  #
  #   AddressFields = Permittable.fields do
  #     required :city, :string, length: 1..80
  #     optional :zip,  :string, format: /\A\d{5}\z/
  #   end
  #
  #   UserFields = Permittable.fields do
  #     required :name,  :string
  #     required :email, :string, format: URI::MailTo::EMAIL_REGEXP
  #     optional :plan,  :string, in: %w[free pro], default: "free"
  #     optional :address do
  #       use AddressFields
  #     end
  #   end
  #
  #   class UsersController < ApplicationController
  #     include Permittable
  #
  #     permit_params :create, root: :user, model: User do
  #       use UserFields
  #     end
  #
  #     # PATCH: same fields, nothing mandatory.
  #     permit_params :update, root: :user, model: User do
  #       use UserFields, optional: true
  #     end
  #   end
  #
  # A group is built by the same ContractBuilder a contract is, so every
  # declaration is validated when the GROUP is defined — a typo fails at the
  # group, once, rather than at each contract that uses it. It is frozen on
  # construction and its fields are frozen hashes, so one group is safely
  # shared by any number of contracts, and `use` splices without copying.
  #
  # What a group deliberately is not: a contract. It has no `root:`,
  # `unknown:`, `model:` or `mode:` — those belong to the request being
  # validated, not to a set of fields — and `finalize` is rejected for the
  # same reason.
  class FieldGroup
    # The frozen field hashes, in declaration order.
    attr_reader :fields

    class << self
      alias define new
    end

    def initialize(&block)
      raise ArgumentError, "#{LABEL}: Permittable.fields requires a block declaring the fields" unless block

      builder = ContractBuilder.new
      @fields = builder.build(&block)
      raise ArgumentError, "#{LABEL}: a field group must declare at least one field" if @fields.empty?
      if builder.finalizer
        raise ArgumentError, "#{LABEL}: finalize belongs to a contract, not a field group — " \
                             "declare it in the permit_params block that uses this group"
      end

      freeze
    end

    # Top-level field names, in declaration order — what `only:`/`except:`
    # select from.
    def names
      @fields.map { |field| field[:name] }
    end
  end
end
