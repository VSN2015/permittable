RSpec.describe Permittable::Generator do
  def permittable_class(&declaration)
    Class.new(FakeController) do
      include Permittable

      class_eval(&declaration) if declaration
    end
  end

  def controller(klass, params: {}, action: "create")
    c = klass.new(params: params)
    c.define_singleton_method(:action_name) { action }
    c
  end

  describe ".scan" do
    it "extracts the root and scalar keys from a require().permit() call" do
      scan = described_class.scan("params.require(:user).permit(:name, :age)")
      expect(scan.root).to eq(:user)
      expect(scan.scalars).to eq(%i[name age])
      expect(scan).to be_found
    end

    it "handles a rootless params.permit call" do
      scan = described_class.scan("params.permit(:q, :page)")
      expect(scan.root).to be_nil
      expect(scan.scalars).to eq(%i[q page])
    end

    it "classifies `key: []` as an array and `key: [:a, :b]` as nested" do
      scan = described_class.scan("params.require(:user).permit(:name, tag_names: [], address: [:city, :zip])")
      expect(scan.scalars).to eq(%i[name])
      expect(scan.arrays).to eq(%i[tag_names])
      expect(scan.nested).to eq(address: %i[city zip])
    end

    it "merges multiple permit calls, keeping the first root found" do
      source = <<~RUBY
        def create
          User.create!(params.require(:user).permit(:name))
        end

        def update
          user.update!(params.require(:user).permit(:name, :age))
        end
      RUBY
      scan = described_class.scan(source)
      expect(scan.root).to eq(:user)
      expect(scan.scalars).to eq(%i[name age])
    end

    it "parses a multiline permit call" do
      source = <<~RUBY
        params.require(:user).permit(
          :name,
          :age,
          tag_names: []
        )
      RUBY
      scan = described_class.scan(source)
      expect(scan.scalars).to eq(%i[name age])
      expect(scan.arrays).to eq(%i[tag_names])
    end

    it "records arguments it cannot parse instead of guessing" do
      scan = described_class.scan("params.require(:user).permit(:name, *extra_keys)")
      expect(scan.scalars).to eq(%i[name])
      expect(scan.unparsed).to eq(["*extra_keys"])
    end

    it "accepts string-keyed permit arguments, at the top level and inside nested lists" do
      scan = described_class.scan(%q{params.require(:user).permit("name", 'age', address: ["city", :zip])})
      expect(scan.scalars).to eq(%i[name age])
      expect(scan.nested).to eq(address: %i[city zip])
      expect(scan.unparsed).to eq([])
    end

    it "keeps mismatched quotes unparsed rather than guessing" do
      scan = described_class.scan(%q{params.permit(:ok, "broken')})
      expect(scan.scalars).to eq(%i[ok])
      expect(scan.unparsed).not_to be_empty
    end

    it "reports found? false when the source has no permit calls" do
      expect(described_class.scan("def index; end")).not_to be_found
    end
  end

  describe ".scan of Rails 8 params.expect calls" do
    it "reads the required root envelope and its scalar keys" do
      scan = described_class.scan("params.expect(user: [:name, :age])")
      expect(scan.root).to eq(:user)
      expect(scan.scalars).to eq(%i[name age])
      expect(scan).to be_found
    end

    it "classifies arrays, nested hashes, and arrays of hashes inside the envelope" do
      scan = described_class.scan(<<~RUBY)
        params.expect(user: [:name, tag_names: [], address: [:city, :zip], line_items: [[:sku, :quantity]]])
      RUBY
      expect(scan.scalars).to eq(%i[name])
      expect(scan.arrays).to eq(%i[tag_names])
      expect(scan.nested).to eq(address: %i[city zip])
      expect(scan.nested_arrays).to eq(line_items: %i[sku quantity])
    end

    it "reads a rootless expect as scalars, like a filter contract" do
      scan = described_class.scan("params.expect(:q, :page)")
      expect(scan.root).to be_nil
      expect(scan.scalars).to eq(%i[q page])
    end

    it "keeps route params alongside an envelope visible instead of drafting them as fields" do
      scan = described_class.scan("params.expect(:id, user: [:name])")
      expect(scan.root).to eq(:user)
      expect(scan.scalars).to eq(%i[name])
      expect(scan.unparsed).to eq([":id"])
    end

    it "keeps a second envelope visible rather than flattening it into the first" do
      scan = described_class.scan("params.expect(user: [:name], address: [:city])")
      expect(scan.root).to eq(:user)
      expect(scan.scalars).to eq(%i[name])
      expect(scan.unparsed).to eq(["address: [:city]"])
    end

    it "does not mistake an array-of-scalars root for an envelope" do
      scan = described_class.scan("params.expect(tag_names: [])")
      expect(scan.root).to be_nil
      expect(scan.arrays).to eq(%i[tag_names])
    end

    it "skips a call whose arguments contain a method call, rather than half-reading it" do
      scan = described_class.scan("params.expect(user: [:name, *extra_keys()])")
      expect(scan).not_to be_found
    end

    it "merges expect and permit calls from the same controller" do
      scan = described_class.scan(<<~RUBY)
        def create
          params.expect(user: [:name])
        end

        def update
          params.require(:user).permit(:email)
        end
      RUBY
      expect(scan.root).to eq(:user)
      expect(scan.scalars).to eq(%i[email name])
      expect(scan.calls).to eq(2)
    end

    it "still leaves an unrecognised argument shape unparsed" do
      scan = described_class.scan("params.expect(user: [:name, weird: { a: 1 }])")
      expect(scan.scalars).to eq(%i[name])
      expect(scan.unparsed).to eq(["weird: { a: 1 }"])
    end
  end

  describe ".draft from an expect scan" do
    it "drafts an array of hashes with no TODO, because the syntax says so" do
      draft = described_class.draft(scan: described_class.scan("params.expect(order: [:ref, line_items: [[:sku]]])"))
      expect(draft).to include("array :line_items do")
      expect(draft).to include("  optional :sku, :string # TODO: confirm the type")
      expect(draft).not_to include("if this is an array of hashes")
    end

    it "produces a draft that loads as a real contract" do
      source = "params.expect(user: [:name, address: [:city], line_items: [[:sku]]])"
      klass = permittable_class { class_eval(Permittable::Generator.draft(scan: Permittable::Generator.scan(source))) }
      params = { user: { name: "Jo", address: { city: "Hanoi" }, line_items: [{ sku: "A-1" }] } }
      result = controller(klass, params: params).permitted_params
      expect(result["name"]).to eq("Jo")
      expect(result["address"].to_h).to eq("city" => "Hanoi")
      expect(result["line_items"].first.to_h).to eq("sku" => "A-1")
    end
  end

  describe ".scan and things that are not code" do
    it "does not read a commented-out permit call" do
      scan = described_class.scan(<<~RUBY)
        def create
          # Legacy, kept for reference:
          # params.require(:admin).permit(:superuser, :impersonate_id)
          params.require(:user).permit(:name)
        end
      RUBY
      expect(scan.root).to eq(:user)
      expect(scan.scalars).to eq(%i[name])
      expect(scan.calls).to eq(1)
    end

    it "does not read a trailing comment on a live line" do
      scan = described_class.scan('params.permit(:name) # was params.permit(:admin)')
      expect(scan.scalars).to eq(%i[name])
      expect(scan.calls).to eq(1)
    end

    it "does not read a permit call inside an =begin/=end block" do
      scan = described_class.scan(<<~RUBY)
        =begin
        params.require(:old).permit(:legacy)
        =end
        params.permit(:name)
      RUBY
      expect(scan.root).to be_nil
      expect(scan.scalars).to eq(%i[name])
    end

    it "keeps a `#` that is part of a string or interpolation, not a comment" do
      scan = described_class.scan(<<~RUBY)
        LABEL = "tracking #1"
        def create = params.require(:user).permit(:name)
      RUBY
      expect(scan.root).to eq(:user)
      expect(scan.scalars).to eq(%i[name])
    end

    it "still reads quoted permit keys, which live in string tokens" do
      scan = described_class.scan(%(params.permit("name", 'email', :age)))
      expect(scan.scalars).to eq(%i[name email age])
    end

    it "falls back to the raw source when the file cannot be lexed" do
      scan = described_class.scan("def broken( ; params.permit(:name)")
      expect(scan.scalars).to eq(%i[name])
    end
  end

  describe ".draft from a model's columns" do
    before do
      ActiveRecord::Schema.define do
        create_table :gen_articles do |t|
          t.string   :title, null: false
          t.text     :body
          t.integer  :views
          t.float    :rating
          t.decimal  :price
          t.boolean  :published
          t.date     :published_on
          t.datetime :locked_at
          t.string   :status, null: false, default: "draft"
          t.json     :settings
          t.binary   :thumbnail
          t.timestamps
        end
      end
      stub_const("GenArticle", Class.new(TestModel) { self.table_name = "gen_articles" })
    end

    after { ActiveRecord::Base.connection.drop_table(:gen_articles, if_exists: true) }

    let(:draft) { described_class.draft(model: GenArticle) }

    it "wraps the fields in monitor-mode permit_params calls with root and model" do
      expect(draft).to include("permit_params :create, root: :gen_article, model: GenArticle, mode: :monitor do")
      expect(draft).to include("permit_params :update, root: :gen_article, model: GenArticle, mode: :monitor do")
      expect(draft).to end_with("end\n")
    end

    it "maps every column type onto the matching contract type" do
      expect(draft).to include("required :title, :string")
      expect(draft).to include("optional :body, :string")
      expect(draft).to include("optional :views, :integer")
      expect(draft).to include("optional :rating, :float")
      expect(draft).to include("optional :price, :decimal")
      expect(draft).to include("optional :published, :boolean")
      expect(draft).to include("optional :published_on, :date")
      expect(draft).to include("optional :locked_at, :datetime")
    end

    it "marks NOT NULL columns without a database default as required" do
      expect(draft).to include("required :title, :string")
      expect(draft).to match(/optional :status, :string\s+# database default: "draft"/)
    end

    it "skips the primary key and timestamps" do
      expect(draft).not_to include(":id")
      expect(draft).not_to include("created_at")
      expect(draft).not_to include("updated_at")
    end

    it "skips every column of a composite primary key (Rails 7.1+ returns an Array)" do
      composite = Class.new(TestModel) do
        self.table_name = "gen_articles"

        def self.primary_key
          %w[id views]
        end
      end
      stub_const("GenCompositeArticle", composite)
      draft = described_class.draft(model: GenCompositeArticle)
      expect(draft).not_to include(":id")
      expect(draft).not_to include(":views")
      expect(draft).to include("required :title, :string")
    end

    it "maps a json column onto the opaque :json contract type" do
      expect(draft).to include("optional :settings, :json")
    end

    it "leaves a TODO comment for columns with no contract type at all" do
      expect(draft).to match(/# TODO: thumbnail \(binary\) has no contract type/)
    end

    it "produces a draft that loads as a real contract and validates a request" do
      klass = permittable_class { class_eval(Permittable::Generator.draft(model: GenArticle)) }
      expect(klass.permit_rule_for("create")).not_to be_nil

      params = { gen_article: { title: "Hello", views: "3" } }
      expect(controller(klass, params: params).permitted_params).to eq("title" => "Hello", "views" => 3)
    end
  end

  describe ".draft of a contract the model would actually accept" do
    after do
      %i[gen_blog_posts gen_orders gen_shipments gen_vehicles gen_fleet_cars gen_oddities].each do |table|
        ActiveRecord::Base.connection.drop_table(table, if_exists: true)
      end
    end

    def load_draft(draft)
      permittable_class { class_eval(draft) }
    end

    def violations(klass, params, action:)
      controller(klass, params: params, action: action).permittable_violations
    end

    # The schema's own spelling of lock_version's `default: 0`, which the
    # draft echoes: "0" from the sqlite adapter through Rails 8.0, 0 in 8.1.
    def lock_default
      ActiveRecord::Base.connection.columns(:gen_vehicles).find { |c| c.name == "lock_version" }.default.inspect
    end

    context "with a namespaced model" do
      before do
        ActiveRecord::Schema.define do
          create_table(:gen_blog_posts) { |t| t.string :title }
        end
        stub_const("Blog::Post", Class.new(TestModel) { self.table_name = "gen_blog_posts" })
      end

      it "roots the draft at model_name.param_key, which is what Rails forms submit" do
        draft = described_class.draft(model: Blog::Post)
        expect(draft).to include("root: :blog_post, model: Blog::Post")
        expect(violations(load_draft(draft), { blog_post: { title: "Hi" } }, action: "create")).to eq([])
      end

      it "keeps a single :create, :update rule when no column is required" do
        draft = described_class.draft(model: Blog::Post)
        expect(draft.scan("permit_params").length).to eq(1)
        expect(draft).to include("permit_params :create, :update, root: :blog_post")
      end
    end

    context "with NOT NULL columns and a partial update" do
      before do
        ActiveRecord::Schema.define do
          create_table :gen_blog_posts do |t|
            t.string :title, null: false
            t.text   :body
          end
        end
        stub_const("GenBlogPost", Class.new(TestModel) { self.table_name = "gen_blog_posts" })
      end

      let(:draft) { described_class.draft(model: GenBlogPost) }

      it "drafts a :create rule that requires them and an :update rule that does not" do
        create, update = draft.split("permit_params").drop(1)
        expect(create).to start_with(" :create, ")
        expect(create).to include("required :title, :string")
        expect(update).to start_with(" :update, ")
        expect(update).to include("optional :title, :string")
        expect(update).not_to include("required")
      end

      it "lets a PATCH carrying only the edited field through, while create still insists" do
        klass = load_draft(draft)
        expect(violations(klass, { gen_blog_post: { body: "Edited" } }, action: "update")).to eq([])
        expect(violations(klass, { gen_blog_post: { body: "New" } }, action: "create"))
          .to eq([{ param: "gen_blog_post.title", code: "missing" }])
      end

      it "splits a scanned draft too, since its required fields come from the same columns" do
        scan = described_class.scan("params.require(:gen_blog_post).permit(:title, :body)")
        draft = described_class.draft(model: GenBlogPost, scan: scan)
        expect(draft).to include("permit_params :create, ")
        expect(draft).to include("permit_params :update, ")
        expect(violations(load_draft(draft), { gen_blog_post: { body: "Edited" } }, action: "update")).to eq([])
      end
    end

    context "with a Rails enum" do
      before do
        ActiveRecord::Schema.define do
          create_table :gen_orders do |t|
            t.integer :status, null: false, default: 0
            t.string  :kind
          end
        end
        stub_const("GenOrder", Class.new(TestModel) do
          self.table_name = "gen_orders"
          if ActiveRecord.version >= Gem::Version.new("7.0")
            enum :status, { pending: 0, shipped: 1 }
            enum :kind, { retail: "retail", wholesale: "wholesale" }
          else
            enum status: { pending: 0, shipped: 1 }
            enum kind: { retail: "retail", wholesale: "wholesale" }
          end
        end)
      end

      let(:draft) { described_class.draft(model: GenOrder) }

      it "drafts the enum as the string keys a form sends, read from the model" do
        expect(draft).to include('optional :status, :string, in: GenOrder.statuses.keys # database default: "pending"')
      end

      it "accepts an enum key and rejects anything else" do
        klass = load_draft(draft)
        expect(violations(klass, { gen_order: { status: "shipped" } }, action: "update")).to eq([])
        expect(violations(klass, { gen_order: { status: "lost" } }, action: "update"))
          .to eq([{ param: "gen_order.status", code: "inclusion" }])
      end

      it "leaves a TODO for the stored integers, which Rails also assigns but :string passes on as text" do
        expect(draft).to match(
          /optional :status, .*; TODO: Rails also assigns the stored integers \(status: 1\).*GenOrder\.statuses\.values/
        )
      end

      it "leaves no stored-integer TODO on an enum whose stored values are strings" do
        expect(draft.lines.grep(/:kind\b/)).to eq(["  optional :kind, :string, in: GenOrder.kinds.keys\n"])
      end

      it "reaches an enum whose accessor is not a method name through defined_enums, so the draft loads" do
        ActiveRecord::Schema.define do
          create_table(:gen_oddities) { |t| t.integer "first-status" }
        end
        stub_const("GenOddEnum", Class.new(TestModel) do
          self.table_name = "gen_oddities"
          if ActiveRecord.version >= Gem::Version.new("7.0")
            enum :'first-status', { open: 0, closed: 1 }, prefix: true
          else
            enum "first-status" => { open: 0, closed: 1 }, _prefix: true
          end
        end)
        draft = described_class.draft(model: GenOddEnum)
        expect(draft).to include('optional :"first-status", :string, in: GenOddEnum.defined_enums["first-status"].keys')
        expect(draft).to include('add GenOddEnum.defined_enums["first-status"].values.map(&:to_s) to in:')

        klass = load_draft(draft)
        expect(violations(klass, { gen_odd_enum: { "first-status" => "closed" } }, action: "update")).to eq([])
        expect(violations(klass, { gen_odd_enum: { "first-status" => "ajar" } }, action: "update"))
          .to eq([{ param: "gen_odd_enum.first-status", code: "inclusion" }])
      end
    end

    context "with defaults the model declares rather than the database" do
      before do
        ActiveRecord::Schema.define do
          create_table :gen_shipments do |t|
            t.integer :status, null: false
            t.string  :carrier, null: false
            t.string  :token, null: false
            t.json    :prefs
            t.decimal :fee
            t.float   :weight
            t.datetime :ships_at
          end
        end
        # A type whose cast is app code that must not run while drafting —
        # the note is written from the default as declared, never cast.
        loud = Class.new(ActiveModel::Type::String) do
          def cast(_value) = raise("a type cast ran while drafting")
          def deserialize(_value) = raise("a type deserialize ran while drafting")
        end
        stub_const("GenShipment", Class.new(TestModel) do
          self.table_name = "gen_shipments"
          if ActiveRecord.version >= Gem::Version.new("7.0")
            enum :status, { pending: 0, shipped: 1 }, default: :pending
          else
            enum status: { pending: 0, shipped: 1 }, _default: "pending"
          end
          attribute :carrier, loud.new, default: "post"
          attribute :prefs, :json, default: {}
          attribute :fee, :decimal, default: BigDecimal("1.5")
          attribute :weight, :float, default: 2.5
          attribute :ships_at, :datetime, default: Time.utc(2026, 1, 1)
          # Calling this would be a side effect of drafting (and its value
          # today says nothing about tomorrow's), so the draft must not.
          attribute :token, :string, default: -> { raise "a Proc default was called while drafting" }
        end)
      end

      let(:draft) { described_class.draft(model: GenShipment) }

      it "does not require a NOT NULL column the model fills in, and shows an enum's default as its key" do
        expect(draft).to include('optional :status, :string, in: GenShipment.statuses.keys # model default: "pending"')
        expect(draft).to include('optional :carrier, :string # model default: "post"')
        expect(draft).to include("optional :token, :string # model default: computed by a Proc")
        expect(draft).not_to include("required")
      end

      it "writes each default as declared, without casting it, in a readable form" do
        expect(draft).to include("optional :prefs, :json # model default: {}")
        expect(draft).to include("optional :fee, :decimal # model default: 1.5\n")
        expect(draft).to include("optional :weight, :float # model default: 2.5\n")
        expect(draft).to include("optional :ships_at, :datetime # model default: 2026-01-01 00:00:00 UTC\n")
      end

      it "keeps one rule, which loads and accepts a create that omits them" do
        expect(draft.scan("permit_params").length).to eq(1)
        expect(violations(load_draft(draft), { gen_shipment: { carrier: "ups" } }, action: "create")).to eq([])
      end
    end

    context "when the model raises while it is being read" do
      before do
        ActiveRecord::Schema.define do
          create_table :gen_vehicles do |t|
            t.string  :type
            t.string  :name, null: false
            t.string  :colour
            t.integer :lock_version, null: false, default: 0
          end
        end
        stub_const("GenBrokenVehicle", Class.new(TestModel) { self.table_name = "gen_vehicles" })
        # Break reading two columns' defaults — an ordinary one and the
        # locking column — after the schema has loaded, so the error comes
        # from the introspection on top of it.
        defaults = GenBrokenVehicle._default_attributes
        allow(defaults).to receive(:[]).and_call_original
        %w[name lock_version].each do |name|
          allow(defaults).to receive(:[]).with(name).and_raise(ArgumentError, "misconfigured\nsecond line")
        end
      end

      let(:draft) { described_class.draft(model: GenBrokenVehicle) }

      it "degrades only the column it could not read, and says so in a TODO" do
        expect(draft).to include(
          "required :name, :string # TODO: could not read what the model adds to name " \
          "(ArgumentError: misconfigured second line) — check its enum and default by hand\n"
        )
        expect(draft).to include("optional :colour, :string\n")
        expect(load_draft(draft).permit_rule_for("update")[:fields].map { |f| f[:name] }).to eq(%i[name colour])
      end

      it "still keeps the STI and locking columns out of the fields" do
        expect(draft).not_to match(/^\s*(required|optional) :(type|lock_version)\b/)
        expect(draft).to include("# TODO: type is the STI inheritance column")
        expect(draft).to include("# TODO: lock_version is the optimistic-locking column")
      end

      it "still drafts nothing from the model when the schema itself cannot be read" do
        stub_const("GenUnreachable", Class.new(TestModel) { self.table_name = "gen_vehicles" })
        allow(GenUnreachable).to receive(:columns).and_raise(ActiveRecord::StatementInvalid, "no such table")
        expect(described_class.draft(model: GenUnreachable)).to be_nil
      end
    end

    context "with STI and optimistic locking" do
      before do
        ActiveRecord::Schema.define do
          create_table :gen_vehicles do |t|
            t.string  :type
            t.string  :name
            t.integer :lock_version, null: false, default: 0
          end
        end
        stub_const("GenVehicle", Class.new(TestModel) { self.table_name = "gen_vehicles" })
      end

      let(:draft) { described_class.draft(model: GenVehicle) }

      it "does not draft the inheritance or locking column as a client-writable field" do
        expect(draft).not_to match(/^\s*(required|optional) :type\b/)
        expect(draft).not_to match(/^\s*(required|optional) :lock_version\b/)
        expect(draft).to include("optional :name, :string")
      end

      it "names each omitted column in a TODO saying why" do
        expect(draft).to match(/# TODO: type is the STI inheritance column — .*changes the record's class/)
        expect(draft).to match(/# TODO: lock_version is the optimistic-locking column — /)
      end

      it "leaves a plain `type` column alone when the model has turned STI off" do
        stub_const("GenPlainVehicle", Class.new(TestModel) do
          self.table_name = "gen_vehicles"
          self.inheritance_column = nil
        end)
        expect(described_class.draft(model: GenPlainVehicle)).to include("optional :type, :string")
      end

      it "loads" do
        expect(load_draft(draft).permit_rule_for("update")[:fields].map { |f| f[:name] }).to eq(%i[name])
      end

      it "says to declare lock_version here when the draft is one :create, :update rule" do
        expect(draft.scan("permit_params").length).to eq(1)
        expect(draft).to include("declare `optional :lock_version, :integer` here")
        expect(draft).not_to include(":update rule")
      end

      it "points the :create rule at the :update rule when the draft splits" do
        ActiveRecord::Schema.define do
          create_table :gen_fleet_cars do |t|
            t.string  :vin, null: false
            t.integer :lock_version, null: false, default: 0
          end
        end
        stub_const("GenFleetCar", Class.new(TestModel) { self.table_name = "gen_fleet_cars" })
        create, update = described_class.draft(model: GenFleetCar).split("permit_params").drop(1)
        expect(create).to include("declare `optional :lock_version, :integer` in the :update rule below")
        expect(update).to include("declare `optional :lock_version, :integer` here")
      end

      it "keeps them as fields, with a TODO, when the controller's own permit call lists them" do
        scan = described_class.scan("params.require(:gen_vehicle).permit(:name, :type, :lock_version)")
        draft = described_class.draft(model: GenVehicle, scan: scan)
        expect(draft).to match(
          /^\s*optional :lock_version, :integer # database default: #{lock_default}; TODO: lock_version is the optimistic-locking/
        )
        expect(draft).to match(/^\s*optional :type, :string # TODO: type is the STI inheritance column — kept because/)

        klass = load_draft(draft)
        params = { gen_vehicle: { name: "Van", lock_version: "3" } }
        expect(violations(klass, params, action: "update")).to eq([])
        expect(controller(klass, params: params, action: "update").permitted_params)
          .to eq("name" => "Van", "lock_version" => 3)
      end

      it "treats lock_version as an ordinary column when the model has turned optimistic locking off" do
        stub_const("GenUnlockedVehicle", Class.new(TestModel) do
          self.table_name = "gen_vehicles"
          self.lock_optimistically = false
        end)
        draft = described_class.draft(model: GenUnlockedVehicle)
        expect(draft).to include("optional :lock_version, :integer # database default: #{lock_default}")
        expect(draft).not_to include("optimistic-locking")
      end
    end

    context "with no column a client should write" do
      after { ActiveRecord::Base.connection.drop_table(:gen_empties, if_exists: true) }

      def model_on(&columns)
        ActiveRecord::Schema.define { create_table(:gen_empties, &columns) }
        stub_const("GenEmpty", Class.new(TestModel) { self.table_name = "gen_empties" })
      end

      # A rule with no field raises `a contract must declare at least one
      # field` when pasted, so there is nothing loadable to draft: nil, which
      # the rake task already skips.
      it "drafts nothing for a model whose only columns are the STI and locking ones" do
        model_on do |t|
          t.string  :type
          t.integer :lock_version, null: false, default: 0
        end
        expect(described_class.draft(model: GenEmpty)).to be_nil
      end

      it "drafts nothing when the rest has no contract type" do
        model_on do |t|
          t.string :type
          t.binary :thumbnail
        end
        expect(described_class.draft(model: GenEmpty)).to be_nil
      end

      it "drafts nothing for a model with only a primary key and timestamps" do
        model_on(&:timestamps)
        expect(described_class.draft(model: GenEmpty)).to be_nil
        expect(described_class.for_controller(Class.new { def self.controller_name = "gen_empties" })).to be_nil
      end

      it "still drafts, and loads, once the permit call lists one of them" do
        model_on do |t|
          t.string  :type
          t.integer :lock_version, null: false, default: 0
        end
        scan = described_class.scan("params.require(:gen_empty).permit(:lock_version)")
        draft = described_class.draft(model: GenEmpty, scan: scan)
        expect(load_draft(draft).permit_rule_for("update")[:fields].map { |f| f[:name] }).to eq(%i[lock_version])
      end
    end

    context "with column names that are not symbol literals" do
      before do
        ActiveRecord::Schema.define do
          create_table :gen_oddities do |t|
            t.string  "first-name"
            t.boolean "2fa_enabled"
            t.string  "Email Address"
          end
        end
        stub_const("GenOddity", Class.new(TestModel) { self.table_name = "gen_oddities" })
      end

      it "quotes them, so the draft is valid Ruby that loads and reads them" do
        draft = described_class.draft(model: GenOddity)
        expect(draft).to include('optional :"first-name", :string')
        expect(draft).to include('optional :"2fa_enabled", :boolean')
        expect(draft).to include('optional :"Email Address", :string')
        params = { gen_oddity: { "first-name" => "Jo", "2fa_enabled" => "true", "Email Address" => "jo@x.io" } }
        expect(violations(load_draft(draft), params, action: "create")).to eq([])
      end
    end
  end

  describe ".draft from a scan plus a model" do
    before do
      ActiveRecord::Schema.define do
        create_table :gen_users do |t|
          t.string  :name, null: false
          t.integer :age
          t.string  :unrelated_column
        end
      end
      stub_const("GenUser", Class.new(TestModel) { self.table_name = "gen_users" })
    end

    after { ActiveRecord::Base.connection.drop_table(:gen_users, if_exists: true) }

    let(:scan) do
      described_class.scan(
        "params.require(:account).permit(:name, :age, :password_confirmation, tag_names: [], address: [:city])"
      )
    end
    let(:draft) { described_class.draft(model: GenUser, scan: scan) }

    it "includes only the scanned keys, typed from their columns" do
      expect(draft).to include("required :name, :string")
      expect(draft).to include("optional :age, :integer")
      expect(draft).not_to include("unrelated_column")
    end

    it "prefers the scanned root over the model-derived one" do
      expect(draft).to include("root: :account")
    end

    it "marks scanned keys that are not columns as virtual with a TODO" do
      expect(draft).to match(/optional :password_confirmation, :string, virtual: true\s+# TODO: not a database column/)
    end

    it "drafts array and nested keys with confirmation TODOs" do
      expect(draft).to match(/array :tag_names, of: :string\s+# TODO: confirm the element type, and declare length:/)
      expect(draft).to match(/optional :address do\s+# TODO: .*array :address do/)
      expect(draft).to match(/optional :city, :string\s+# TODO: confirm the type/)
    end

    it "surfaces unparsed permit arguments as a TODO instead of dropping them" do
      unparsed = described_class.scan("params.require(:account).permit(:name, *extra)")
      draft = described_class.draft(model: GenUser, scan: unparsed)
      expect(draft).to match(/# TODO: could not parse from the permit call: \*extra/)
    end

    it "produces a draft that loads even with virtual and nested TODO fields" do
      d = draft
      klass = permittable_class { class_eval(d) }
      rule = klass.permit_rule_for("create")
      expect(rule[:root]).to eq(:account)
      expect(rule[:fields].map { |f| f[:name] }).to include(:name, :password_confirmation, :tag_names, :address)
    end
  end

  describe ".draft from a scan alone" do
    let(:scan) { described_class.scan("params.permit(:q, :page)") }
    let(:draft) { described_class.draft(scan: scan) }

    it "stays rootless, omits model:, and asks for type confirmation" do
      expect(draft).to include("permit_params :create, :update, mode: :monitor do")
      expect(draft).not_to include("root:")
      expect(draft).not_to include("model:")
      expect(draft).to match(/optional :q, :string\s+# TODO: confirm the type/)
      expect(draft).to match(/optional :page, :string\s+# TODO: confirm the type/)
    end
  end

  describe ".draft with nothing to go on" do
    it "returns nil" do
      expect(described_class.draft).to be_nil
      expect(described_class.draft(scan: described_class.scan("def index; end"))).to be_nil
    end
  end

  describe ".for_controller" do
    before do
      ActiveRecord::Schema.define do
        create_table :gen_posts do |t|
          t.string :title, null: false
        end
      end
      stub_const("GenPost", Class.new(TestModel) { self.table_name = "gen_posts" })
    end

    after { ActiveRecord::Base.connection.drop_table(:gen_posts, if_exists: true) }

    it "infers the model from controller_name and scans the given source" do
      controller = Class.new do
        def self.controller_name = "gen_posts"
      end
      source = "params.require(:gen_post).permit(:title, :draft_token)"
      draft = described_class.for_controller(controller, source: source)
      expect(draft).to include("root: :gen_post, model: GenPost")
      expect(draft).to include("required :title, :string")
      expect(draft).to include("optional :draft_token, :string, virtual: true")
    end

    it "accepts an explicit model" do
      controller = Class.new { def self.controller_name = "whatever" }
      draft = described_class.for_controller(controller, model: GenPost)
      expect(draft).to include("model: GenPost")
    end

    it "returns nil when there is no model and no permit call to draft from" do
      controller = Class.new { def self.controller_name = "no_such_things" }
      expect(described_class.for_controller(controller, source: "def index; end")).to be_nil
    end
  end
end
