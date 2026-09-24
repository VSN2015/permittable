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

  # Evaluate a generated draft in a throwaway controller class, the way a
  # developer pasting it would, and hand back the resolved create rule. A
  # draft that raises here is a draft that breaks the controller it is pasted
  # into.
  def load_draft(draft)
    expect(draft).to be_a(String)
    klass = permittable_class { class_eval(draft) }
    klass.permit_rule_for("create")
  end

  # A model known only by its name: all the root choice reads from it.
  def named_model(name)
    Class.new.tap { |klass| klass.define_singleton_method(:name) { name } }
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

    it "merges multiple permit calls for the same root" do
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
      expect(scan.route_params).to eq([":id"])
      expect(scan.unparsed).to eq([])
    end

    it "keeps a second envelope visible rather than flattening it into the first" do
      scan = described_class.scan("params.expect(user: [:name], address: [:city])")
      expect(scan.root).to eq(:user)
      expect(scan.scalars).to eq(%i[name])
      expect(scan.other_envelopes).to eq(address: ["address: [:city]"])
      expect(scan.unparsed).to eq([])
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
      expect(scan.scalars).to eq(%i[name email])
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

    it "wraps the fields in a monitor-mode permit_params call with root and model" do
      expect(draft).to include("permit_params :create, :update, root: :gen_article, model: GenArticle, mode: :monitor do")
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

  describe ".scan across calls with different envelopes" do
    it "keeps a Rails 8 scaffold's separate `expect(:id)` out of the envelope" do
      scan = described_class.scan(<<~RUBY)
        def set_post
          @post = Post.find(params.expect(:id))
        end

        def post_params
          params.expect(post: [:title, :body])
        end
      RUBY
      expect(scan.root).to eq(:post)
      expect(scan.scalars).to eq(%i[title body])
      expect(scan.route_params).to eq([":id"])
      expect(scan.unparsed).to eq([])
    end

    it "gives the envelope a tie with a rootless call, so a one-field scaffold keeps its root" do
      scan = described_class.scan("Post.find(params.expect(:id))\nparams.expect(post: [:title])")
      expect(scan.root).to eq(:post)
      expect(scan.scalars).to eq(%i[title])
      expect(scan.route_params).to eq([":id"])
    end

    it "keeps a rootless permit call out of the envelope, wherever it appears" do
      scan = described_class.scan(<<~RUBY)
        def index
          @posts = Post.page(params.permit(:page, :per_page))
        end

        def post_params
          params.require(:post).permit(:title, :body, :published)
        end
      RUBY
      expect(scan.root).to eq(:post)
      expect(scan.scalars).to eq(%i[title body published])
      expect(scan.rootless).to eq([":page", ":per_page"])
    end

    it "roots nothing when the model is known and the rootless calls carry the most fields" do
      scan = described_class.scan(<<~RUBY, model: named_model("Article"))
        def index = params.require(:filter).permit(:q)
        def create = params.permit(:title, :body, :published)
      RUBY
      expect(scan.root).to be_nil
      expect(scan.scalars).to eq(%i[title body published])
      expect(scan.other_envelopes).to eq(filter: ["filter: [:q]"])
      expect(scan.rootless).to eq([])
    end

    it "prefers any envelope to rootless calls when the model is not known, as before" do
      scan = described_class.scan("params.require(:post).permit(:title)
params.permit(:page, :per_page)")
      expect(scan.root).to eq(:post)
      expect(scan.scalars).to eq(%i[title])
      expect(scan.rootless).to eq([":page", ":per_page"])
    end

    it "does not call a losing rootless call's keys route params" do
      source = "params.permit(:title, :body)\nparams.require(:filter).permit(:q)"
      draft = described_class.draft(scan: described_class.scan(source))
      expect(draft).to include("root: :filter")
      expect(draft).to include("# TODO: outside the filter envelope, so not in this contract: :title")
      expect(draft).not_to include("route or query param")
      expect(load_draft(draft)[:fields].map { |f| f[:name] }).to eq(%i[q])
    end

    it "prefers an envelope with no parsed field to rootless calls when the model is not known" do
      draft = described_class.draft(scan: described_class.scan("params.require(:post).permit(*PERMITTED)
params.permit(:page)"))
      expect(draft).to be_nil # no fields and no columns: nothing loadable to draft
      expect(described_class.scan("params.require(:post).permit(*PERMITTED)
params.permit(:page)").root).to eq(:post)
    end

    it "keeps a second permit envelope visible rather than merging it into the first" do
      scan = described_class.scan(<<~RUBY)
        params.require(:post).permit(:title, :body)
        params.require(:search).permit(:q, tags: [])
      RUBY
      expect(scan.root).to eq(:post)
      expect(scan.scalars).to eq(%i[title body])
      expect(scan.arrays).to eq([])
      expect(scan.other_envelopes).to eq(search: ["search: [:q, tags: []]"])
    end

    it "roots the draft at the envelope with the most fields, not a search form seen first" do
      scan = described_class.scan(<<~RUBY)
        def index = params.require(:search).permit(:q)
        def create = params.require(:post).permit(:title, :body)
      RUBY
      expect(scan.root).to eq(:post)
      expect(scan.scalars).to eq(%i[title body])
      expect(scan.other_envelopes).to eq(search: ["search: [:q]"])
    end

    it "breaks a tie by source order, whichever call spelling comes first" do
      scan = described_class.scan("params.expect(post: [:title])\nparams.require(:search).permit(:q)")
      expect(scan.root).to eq(:post)
      expect(scan.other_envelopes).to eq(search: ["search: [:q]"])
    end

    it "counts only parsed fields, not arguments it could not read" do
      scan = described_class.scan("params.require(:search).permit(:q)\nparams.require(:post).permit(*PERMITTED, **opts)")
      expect(scan.root).to eq(:search)
      expect(scan.other_envelopes).to eq(post: ["post: [*PERMITTED, **opts]"])
    end

    it "counts every envelope of an expect call, so a second one can be the chosen root" do
      scan = described_class.scan(<<~RUBY)
        params.expect(post: [:title], comment: [:body])
        params.expect(comment: [:body, :author])
      RUBY
      expect(scan.root).to eq(:comment)
      expect(scan.scalars).to eq(%i[body author])
      expect(scan.other_envelopes).to eq(post: ["post: [:title]"])
    end

    it "still drafts a file of only rootless calls as scalars" do
      scan = described_class.scan("params.permit(:q)\nparams.expect(:page)")
      expect(scan.root).to be_nil
      expect(scan.scalars).to eq(%i[q page])
      expect(scan.unparsed).to eq([])
    end

    it "does not mistake a spaced `tag_names: [ ]` for an envelope" do
      scan = described_class.scan("params.expect(tag_names: [ ])")
      expect(scan.root).to be_nil
      expect(scan.arrays).to eq(%i[tag_names])
    end
  end

  describe ".draft of calls kept out of the contract" do
    let(:draft) do
      described_class.draft(scan: described_class.scan(<<~RUBY))
        Post.find(params.expect(:id))
        params.require(:search).permit(:q)
        params.require(:post).permit(:title, :body, *EXTRA)
      RUBY
    end

    it "says why each one is a TODO, and does not call parsed arguments unparsable" do
      expect(draft).to include("# TODO: belongs to another envelope (search): search: [:q]")
      expect(draft).to include("# TODO: route or query param, not a body field: :id")
      expect(draft).to include("# TODO: could not parse from the permit call: *EXTRA")
      expect(draft.scan("could not parse").size).to eq(1)
      expect(load_draft(draft)[:root]).to eq(:post)
    end
  end

  describe ".draft of a scanned key that is not a bare symbol" do
    it "quotes it, so the draft is valid Ruby" do
      draft = described_class.draft(scan: described_class.scan('params.require(:user).permit("2fa", codes: ["2fa"])'))
      expect(draft).to include(%(optional :"2fa", :string # TODO: confirm the type))
      expect(draft).to include("optional :codes do")
      expect(draft).to include(%(  optional :"2fa", :string))
      expect(load_draft(draft)[:fields].map { |f| f[:name] }).to eq(%i[2fa codes])
    end
  end

  describe ".scan of a key permitted in two shapes" do
    it "keeps the richer shape and names the conflict" do
      scan = described_class.scan(<<~RUBY)
        params.require(:user).permit(:tags, :address, :items)
        params.require(:user).permit(tags: [], address: [:city], items: [:sku])
        params.expect(user: [items: [[:sku, :qty]]])
      RUBY
      expect(scan.scalars).to eq([])
      expect(scan.arrays).to eq(%i[tags])
      expect(scan.nested).to eq(address: %i[city])
      expect(scan.nested_arrays).to eq(items: %i[sku qty])
      expect(scan.conflicts).to contain_exactly(
        "tags is permitted as both a scalar and an array — drafted as the array",
        "address is permitted as both a scalar and a nested hash — drafted as the nested hash",
        "items is permitted as a scalar, a nested hash and an array of hashes — " \
        "drafted as the array of hashes with the nested hash's sub-keys merged in, dropping the scalar"
      )
    end

    it "merges the sub-keys of a nested hash into the array of hashes that wins" do
      scan = described_class.scan("params.require(:u).permit(items: [:sku, :name])\nparams.expect(u: [items: [[:qty]]])")
      expect(scan.nested).to eq({})
      expect(scan.nested_arrays).to eq(items: %i[qty sku name])
      expect(scan.conflicts).to contain_exactly(
        "items is permitted as both a nested hash and an array of hashes — " \
        "drafted as the array of hashes with the nested hash's sub-keys merged in"
      )
    end

    it "names every shape when a scalar joins shapes that accept different input" do
      scan = described_class.scan("params.require(:u).permit(:name, :tags, tags: [])\nparams.require(:u).permit(tags: [:a])")
      expect(scan.scalars).to eq(%i[name])
      expect(scan.conflicts).to contain_exactly(
        "tags is permitted as a scalar, an array and a nested hash, which accept different input — " \
        "drafted as none of them; declare the shape its actions share"
      )
    end

    it "reads an empty nested list as unparsable, never as an empty block" do
      scan = described_class.scan("params.require(:u).permit(:name, meta: [ , ])\nparams.expect(u: [opts: [[ ]]])")
      expect(scan.nested).to eq({})
      expect(scan.nested_arrays).to eq({})
      expect(scan.unparsed).to eq(["meta: [ , ]", "opts: [[ ]]"])
      expect(load_draft(described_class.draft(scan: scan))[:fields].map { |f| f[:name] }).to eq(%i[name])
    end

    it "drafts neither of an array and a nested hash, which accept different input" do
      source = "params.require(:u).permit(:name, tags: [])\nparams.require(:u).permit(tags: [:a])"
      scan = described_class.scan(source)
      expect(scan.arrays).to eq([])
      expect(scan.nested).to eq({})
      expect(scan.conflicts).to contain_exactly(
        "tags is permitted as both an array and a nested hash, which accept different input — " \
        "drafted as neither; declare the shape its actions share"
      )
      draft = described_class.draft(scan: scan)
      expect(load_draft(draft)[:fields].map { |f| f[:name] }).to eq(%i[name])
    end

    it "drafts neither of an array of scalars and an array of hashes" do
      scan = described_class.scan("params.expect(u: [:name, tags: []])\nparams.expect(u: [tags: [[:a]]])")
      expect(scan.arrays).to eq([])
      expect(scan.nested_arrays).to eq({})
      expect(scan.conflicts.first).to start_with("tags is permitted as both an array and an array of hashes")
    end

    it "drafts each key once, so the draft loads" do
      draft = described_class.draft(scan: described_class.scan(<<~RUBY))
        params.require(:user).permit(:tags, :address)
        params.require(:user).permit(tags: [], address: [:city])
      RUBY
      rule = load_draft(draft)
      expect(rule[:fields].map { |f| f[:name] }).to eq(%i[tags address])
      expect(draft).to include("# TODO: tags is permitted as both a scalar and an array — drafted as the array")
    end
  end

  describe ".draft when the scan found calls but no fields" do
    before do
      ActiveRecord::Schema.define do
        create_table :gen_notes do |t|
          t.string :title, null: false
          t.text   :body
        end
      end
      stub_const("GenNote", Class.new(TestModel) { self.table_name = "gen_notes" })
    end

    after { ActiveRecord::Base.connection.drop_table(:gen_notes, if_exists: true) }

    it "falls back to the columns, keeps the TODO, and loads" do
      scan = described_class.scan("params.require(:note).permit(*PERMITTED)")
      draft = described_class.draft(model: GenNote, scan: scan)
      expect(draft).to include("root: :note, model: GenNote")
      expect(draft).to include("required :title, :string")
      expect(draft).to include("optional :body, :string")
      expect(draft).to include("# TODO: could not parse from the permit call: *PERMITTED")
      expect(load_draft(draft)[:fields].map { |f| f[:name] }).to eq(%i[title body])
    end

    it "keeps a rootless scan rootless, with the columns at the top level" do
      draft = described_class.draft(model: GenNote, scan: described_class.scan("params.permit(*KEYS)"))
      expect(draft).to include("permit_params :create, :update, model: GenNote, mode: :monitor do")
      rule = load_draft(draft)
      expect(rule[:root]).to be(false) # a rule stores "no envelope" as root: false
      expect(rule[:fields].map { |f| f[:name] }).to eq(%i[title body])
    end

    it "returns nil when there are no columns to fall back to either" do
      expect(described_class.draft(scan: described_class.scan("params.permit(*KEYS)"))).to be_nil
    end
  end

  describe ".scan of single-key route-param lookups" do
    it "keeps the scaffold's root beside a rootless filter call" do
      scan = described_class.scan(<<~RUBY)
        def set_post = @post = Post.find(params.expect(:id))
        def index = Post.page(params.permit(:page))
        def post_params = params.expect(post: [:title])
      RUBY
      expect(scan.root).to eq(:post)
      expect(scan.scalars).to eq(%i[title])
      expect(scan.route_params).to eq([":id"])
      expect(scan.rootless).to eq([":page"])
    end

    it "never drafts `:id` or a `*_id` lookup as a field, even when the rootless calls win" do
      scan = described_class.scan(<<~RUBY)
        @post = Post.find(params.expect(:id))
        @user = User.find(params.expect(:user_id))
        params.permit(:q, :page)
      RUBY
      expect(scan.root).to be_nil
      expect(scan.scalars).to eq(%i[q page])
      expect(scan.route_params).to eq([":id", ":user_id"])
    end

    it "still counts `:id` inside a call with other keys" do
      scan = described_class.scan("params.expect(:id, :q)")
      expect(scan.root).to be_nil
      expect(scan.scalars).to eq(%i[id q])
    end

    it "drafts a single-key permit of a `*_id` key, which is a mass-assignment filter, as before" do
      scan = described_class.scan("params.permit(:group_id)")
      expect(scan.scalars).to eq(%i[group_id])
      expect(scan.route_params).to eq([])
      draft = described_class.draft(scan: scan)
      expect(draft).to include("optional :group_id, :string # TODO: confirm the type")
      expect(load_draft(draft)[:fields].map { |f| f[:name] }).to eq(%i[group_id])
    end

    it "returns nil for a model-less file of only route-param lookups" do
      expect(described_class.draft(scan: described_class.scan("Post.find(params.expect(:id))"))).to be_nil
    end
  end

  describe ".scan of an expect envelope spelled with a constant" do
    it "reads `post: PERMITTED_PARAMS` as the post envelope, with fields it cannot parse" do
      scan = described_class.scan("params.expect(post: PERMITTED_PARAMS)")
      expect(scan.root).to eq(:post)
      expect(scan.unparsed).to eq(["PERMITTED_PARAMS"])
      expect(scan).not_to be_fields
    end

    it "quotes a losing constant envelope as the source spells it" do
      draft = described_class.draft(scan: described_class.scan("params.expect(post: PERMITTED)\nparams.require(:search).permit(:q)"))
      expect(draft).to include("# TODO: belongs to another envelope (post): post: PERMITTED")
      expect(load_draft(draft)[:root]).to eq(:search)
    end
  end

  describe ".scan of a body shape beside an expect envelope" do
    it "says it is outside the envelope rather than calling it a route param" do
      draft = described_class.draft(scan: described_class.scan("params.expect(:id, post: [:title], tag_names: [])"))
      expect(draft).to include("# TODO: route or query param, not a body field: :id")
      expect(draft).to include("# TODO: outside the post envelope, so not in this contract: tag_names: []")
      expect(draft).not_to include("route or query param, not a body field: tag_names")
      expect(load_draft(draft)[:root]).to eq(:post)
    end

    it "says it was sent beside another envelope when the rootless calls won" do
      source = "params.expect(post: [:title], tag_names: [])\nparams.permit(:q, :page)"
      draft = described_class.draft(scan: described_class.scan(source, model: named_model("Article")))
      expect(draft).to include("# TODO: sent beside another envelope, so not in this contract: tag_names: []")
      expect(load_draft(draft)[:fields].map { |f| f[:name] }).to eq(%i[q page])
    end
  end

  describe ".for_controller when an envelope is the model's own" do
    before do
      ActiveRecord::Schema.define do
        create_table :gen_posts do |t|
          t.string :title, null: false
          t.text   :body
        end
      end
      stub_const("GenPost", Class.new(TestModel) { self.table_name = "gen_posts" })
    end

    after { ActiveRecord::Base.connection.drop_table(:gen_posts, if_exists: true) }

    let(:controller) { Class.new { def self.controller_name = "gen_posts" } }

    it "roots the draft at the model's envelope, whatever the scores say" do
      source = "params.require(:search).permit(:q, :sort, :page)\nparams.expect(gen_post: [:title])"
      expect(described_class.scan(source, model: GenPost).root).to eq(:gen_post)
      draft = described_class.for_controller(controller, source: source)
      expect(draft).to include("root: :gen_post, model: GenPost")
      expect(draft).to include("# TODO: belongs to another envelope (search): search: [:q, :sort, :page]")
      expect(load_draft(draft)[:root]).to eq(:gen_post)
    end

    it "roots at the model's envelope even with no parsed fields, and falls back to the columns" do
      draft = described_class.for_controller(controller, source: <<~RUBY)
        def index = Post.page(params.permit(:page))
        def gen_post_params = params.require(:gen_post).permit(*PERMITTED)
      RUBY
      expect(draft).to include("root: :gen_post, model: GenPost")
      expect(draft).to include("required :title, :string")
      expect(draft).to include("# TODO: could not parse from the permit call: *PERMITTED")
      expect(draft).to include("# TODO: outside the gen_post envelope, so not in this contract: :page")
      expect(load_draft(draft)[:fields].map { |f| f[:name] }).to eq(%i[title body])
    end

    it "roots at the model when the only readable call is a route-param lookup" do
      draft = described_class.for_controller(controller, source: <<~RUBY)
        def set_post = @post = GenPost.find(params.expect(:id))
        def gen_post_params = params.require(:gen_post).permit(policy(@post).permitted_attributes)
      RUBY
      expect(draft).to include("root: :gen_post, model: GenPost")
      expect(draft).to include("# TODO: route or query param, not a body field: :id")
      expect(load_draft(draft)[:root]).to eq(:gen_post)
    end

    it "falls back to the columns for a constant envelope" do
      draft = described_class.for_controller(controller, source: "params.expect(gen_post: PERMITTED_PARAMS)")
      expect(draft).to include("root: :gen_post, model: GenPost")
      expect(draft).to include("# TODO: could not parse from the permit call: PERMITTED_PARAMS")
      expect(load_draft(draft)[:fields].map { |f| f[:name] }).to eq(%i[title body])
    end

    it "scores the envelopes as before when none is the model's" do
      source = "params.require(:search).permit(:q, :sort)\nparams.require(:post).permit(:title)"
      expect(described_class.scan(source, model: GenPost).root).to eq(:search)
    end
  end

  describe ".draft falling back to the columns beside keys the scan did not draft" do
    before do
      ActiveRecord::Schema.define do
        create_table :gen_tasks do |t|
          t.string  :title
          t.string  :tags
          t.integer :project_id
        end
      end
      stub_const("GenTask", Class.new(TestModel) { self.table_name = "gen_tasks" })
    end

    after { ActiveRecord::Base.connection.drop_table(:gen_tasks, if_exists: true) }

    it "does not declare a column whose shape the scan could not decide" do
      scan = described_class.scan("params.permit(tags: [])\nparams.permit(tags: [:a])")
      draft = described_class.draft(model: GenTask, scan: scan)
      expect(draft).to include("permit_params :create, :update, model: GenTask, mode: :monitor do")
      expect(draft).to include("# TODO: tags is permitted as both an array and a nested hash")
      expect(draft).not_to include("optional :tags")
      expect(load_draft(draft)[:fields].map { |f| f[:name] }).to eq(%i[title project_id])
    end

    it "still declares a column for a key a losing rootless call permitted" do
      scan = described_class.scan("params.require(:gen_task).permit(*PERMITTED)\nparams.permit(:title)", model: GenTask)
      draft = described_class.draft(model: GenTask, scan: scan)
      expect(draft).to include("root: :gen_task, model: GenTask")
      expect(draft).to include("# TODO: outside the gen_task envelope, so not in this contract: :title")
      expect(load_draft(draft)[:fields].map { |f| f[:name] }).to eq(%i[title tags project_id])
    end

    it "does not declare a column the scan read as a route param" do
      draft = described_class.draft(model: GenTask, scan: described_class.scan("GenTask.where(project_id: params.expect(:project_id))"))
      expect(draft).to include("root: :gen_task, model: GenTask")
      expect(draft).to include("# TODO: route or query param, not a body field: :project_id")
      expect(draft).not_to include("optional :project_id")
      expect(load_draft(draft)[:fields].map { |f| f[:name] }).to eq(%i[title tags])
    end
  end

  describe ".draft when no line would declare a field" do
    before do
      ActiveRecord::Schema.define do
        create_table(:gen_blobs) { |t| t.binary :data }
        create_table :gen_files do |t|
          t.string :name
          t.binary :data
        end
      end
      stub_const("GenBlob", Class.new(TestModel) { self.table_name = "gen_blobs" })
      stub_const("GenFile", Class.new(TestModel) { self.table_name = "gen_files" })
    end

    after do
      ActiveRecord::Base.connection.drop_table(:gen_blobs, if_exists: true)
      ActiveRecord::Base.connection.drop_table(:gen_files, if_exists: true)
    end

    it "falls back to the columns when every scanned key is a column with no contract type" do
      draft = described_class.draft(model: GenFile, scan: described_class.scan("params.require(:upload).permit(:data)"))
      expect(draft).to include("root: :upload, model: GenFile")
      expect(draft).to include("optional :name, :string")
      expect(draft).to include("# TODO: data (binary) has no contract type")
      expect(load_draft(draft)[:fields].map { |f| f[:name] }).to eq(%i[name])
    end

    it "returns nil when the columns cannot declare a field either" do
      expect(described_class.draft(model: GenBlob, scan: described_class.scan("params.require(:upload).permit(:data)")))
        .to be_nil
    end

    it "returns nil for a model whose only columns have no contract type" do
      expect(described_class.draft(model: GenBlob)).to be_nil
    end
  end

  describe "every scan-driven draft loads" do
    [
      "params.require(:post).permit(:title, :body)",
      "params.permit(:q, :page)",
      "params.expect(post: [:title, tags: [], address: [:city], items: [[:sku]]])",
      "@post = Post.find(params.expect(:id))\nparams.expect(post: [:title])",
      "params.permit(:page)\nparams.require(:post).permit(:title)\nparams.require(:search).permit(:q)",
      "params.permit(:title, :body)\nparams.require(:filter).permit(:q)",
      "params.expect(post: [:title], comment: [:body, :author])",
      "params.require(:u).permit(:tags, :address)\nparams.require(:u).permit(tags: [], address: [:city])",
      "params.require(:u).permit(:name, items: [:sku])\nparams.expect(u: [items: [[:qty]]])",
      "params.require(:u).permit(:name, tags: [])\nparams.require(:u).permit(tags: [:a])",
      'params.permit("2fa", codes: ["2fa"])',
      "params.expect(tag_names: [ ])",
      "Post.find(params.expect(:id))\nparams.permit(:page)\nparams.expect(post: [:title])",
      "params.permit(:page)\nparams.expect(post: [:title], tag_names: [])",
      "params.require(:u).permit(:name, meta: [ , ], opts: [[ ]])",
      "params.expect(u: [:name, meta: [[ ]]])"
    ].each do |source|
      it "loads the draft of #{source.inspect}" do
        expect { load_draft(described_class.draft(scan: described_class.scan(source))) }.not_to raise_error
      end
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
