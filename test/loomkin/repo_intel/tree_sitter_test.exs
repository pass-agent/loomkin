defmodule Loomkin.RepoIntel.TreeSitterTest do
  use ExUnit.Case, async: true

  alias Loomkin.RepoIntel.TreeSitter

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Initialize the ETS cache
    TreeSitter.init_cache()

    # Create fixture files for each supported language
    File.mkdir_p!(Path.join(tmp_dir, "fixtures"))

    File.write!(Path.join(tmp_dir, "fixtures/example.ex"), """
    defmodule MyApp.Accounts do
      @moduledoc "Manages user accounts."

      defstruct [:id, :name, :email]

      @type t :: %__MODULE__{}

      @callback fetch(integer()) :: {:ok, t()} | {:error, term()}

      @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
      def create(attrs) do
        %__MODULE__{}
        |> changeset(attrs)
        |> Repo.insert()
      end

      defp changeset(struct, attrs) do
        struct
      end

      defmacro validate(field) do
        quote do: validate_required(unquote(field))
      end

      defguard is_admin(user) when user.role == :admin

      defdelegate find(id), to: MyApp.Repo
    end

    defprotocol Displayable do
      def display(data)
    end

    defimpl Displayable, for: MyApp.Accounts do
      def display(account), do: account.name
    end
    """)

    File.write!(Path.join(tmp_dir, "fixtures/app.py"), """
    class UserService:
        \"\"\"Manages users.\"\"\"

        def __init__(self, db):
            self.db = db

        def find_user(self, user_id: int) -> dict:
            return self.db.find(user_id)

        async def async_find(self, user_id):
            return await self.db.async_find(user_id)

    class AdminService(UserService):
        pass

    def helper_function(x, y):
        return x + y

    MAX_RETRIES = 3
    """)

    File.write!(Path.join(tmp_dir, "fixtures/app.ts"), """
    export interface ApiResponse<T> {
      data: T;
      error?: string;
    }

    export type UserId = string;

    export enum Role {
      Admin = "admin",
      User = "user",
    }

    export class ApiClient {
      constructor(private baseUrl: string) {}

      async fetchData(url: string): Promise<ApiResponse<any>> {
        return fetch(url).then(r => r.json());
      }
    }

    export function createClient(url: string): ApiClient {
      return new ApiClient(url);
    }

    export const DEFAULT_URL = "https://api.example.com";
    """)

    File.write!(Path.join(tmp_dir, "fixtures/app.js"), """
    export function fetchData(url) {
      return fetch(url);
    }

    export class ApiClient {
      constructor() {}

      async getData() {
        return {};
      }
    }

    export const API_BASE = "https://api.example.com";

    async function processData(data) {
      return data;
    }
    """)

    File.write!(Path.join(tmp_dir, "fixtures/main.go"), """
    package main

    import "fmt"

    type Config struct {
        Name    string
        Version int
    }

    type Logger interface {
        Log(msg string)
    }

    func main() {
        fmt.Println("hello")
    }

    func NewConfig(name string) *Config {
        return &Config{Name: name}
    }

    func (c *Config) Validate() error {
        return nil
    }
    """)

    File.write!(Path.join(tmp_dir, "fixtures/lib.rs"), """
    pub mod utils {
        pub const MAX_SIZE: usize = 1024;

        pub fn helper() -> bool {
            true
        }
    }

    pub struct Server {
        pub host: String,
        pub port: u16,
    }

    pub enum Status {
        Running,
        Stopped,
    }

    pub trait Handler {
        fn handle(&self, req: Request) -> Response;
    }

    impl Server {
        pub fn new(host: String, port: u16) -> Self {
            Self { host, port }
        }

        fn internal_method(&self) {}
    }

    pub type Result<T> = std::result::Result<T, Error>;
    """)

    File.write!(Path.join(tmp_dir, "fixtures/app.rb"), """
    module Authentication
      class User
        attr_reader :name, :email
        attr_accessor :role

        def initialize(name, email)
          @name = name
          @email = email
        end

        def admin?
          role == :admin
        end

        def self.find(id)
          # find user
        end
      end

      class Admin < User
        def permissions
          [:all]
        end
      end
    end
    """)

    %{tmp_dir: tmp_dir, fixtures: Path.join(tmp_dir, "fixtures")}
  end

  describe "available?/0" do
    test "returns a boolean" do
      result = TreeSitter.available?()
      assert is_boolean(result)
    end
  end

  describe "extract_with_regex/2 - Elixir" do
    test "extracts modules, functions, macros, structs, types, callbacks, guards, protocols",
         %{fixtures: dir} do
      symbols = TreeSitter.extract_with_regex(Path.join(dir, "example.ex"), :elixir)

      names = Enum.map(symbols, & &1.name)
      types = Enum.map(symbols, & &1.type)

      assert "MyApp.Accounts" in names
      assert "create" in names
      assert "changeset" in names
      assert "validate" in names
      assert "is_admin" in names
      assert "find" in names
      assert "Displayable" in names
      assert "defstruct" in names

      assert :module in types
      assert :function in types
      assert :macro in types
      assert :struct in types
      assert :guard in types
      assert :protocol in types
      assert :type in types
      assert :callback in types

      # Verify line numbers are present and valid
      Enum.each(symbols, fn sym ->
        assert is_integer(sym.line)
        assert sym.line > 0
      end)
    end

    test "extracts function signatures", %{fixtures: dir} do
      symbols = TreeSitter.extract_with_regex(Path.join(dir, "example.ex"), :elixir)

      create_sym = Enum.find(symbols, fn s -> s.name == "create" and s.type == :function end)
      assert create_sym
      assert create_sym.signature =~ "create"
    end
  end

  describe "extract_with_regex/2 - Python" do
    test "extracts classes and functions", %{fixtures: dir} do
      symbols = TreeSitter.extract_with_regex(Path.join(dir, "app.py"), :python)

      names = Enum.map(symbols, & &1.name)
      types = Enum.map(symbols, & &1.type)

      assert "UserService" in names
      assert "AdminService" in names
      assert "helper_function" in names
      assert "find_user" in names
      assert "async_find" in names

      assert :class in types
      assert :function in types
    end
  end

  describe "extract_with_regex/2 - TypeScript" do
    test "extracts interfaces, types, enums, classes, functions, constants", %{fixtures: dir} do
      symbols = TreeSitter.extract_with_regex(Path.join(dir, "app.ts"), :typescript)

      names = Enum.map(symbols, & &1.name)
      types = Enum.map(symbols, & &1.type)

      assert "ApiResponse" in names
      assert "UserId" in names
      assert "Role" in names
      assert "ApiClient" in names
      assert "createClient" in names
      assert "DEFAULT_URL" in names

      assert :interface in types
      assert :type in types
      assert :enum in types
      assert :class in types
      assert :function in types
      assert :constant in types
    end
  end

  describe "extract_with_regex/2 - JavaScript" do
    test "extracts functions, classes, constants", %{fixtures: dir} do
      symbols = TreeSitter.extract_with_regex(Path.join(dir, "app.js"), :javascript)

      names = Enum.map(symbols, & &1.name)

      assert "fetchData" in names
      assert "ApiClient" in names
      assert "API_BASE" in names
      assert "processData" in names
    end
  end

  describe "extract_with_regex/2 - Go" do
    test "extracts functions, methods, structs, interfaces", %{fixtures: dir} do
      symbols = TreeSitter.extract_with_regex(Path.join(dir, "main.go"), :go)

      names = Enum.map(symbols, & &1.name)
      types = Enum.map(symbols, & &1.type)

      assert "main" in names or "Config" in names
      assert "Config" in names
      assert "Logger" in names
      assert "NewConfig" in names

      assert :struct in types
      assert :interface in types
      assert :function in types
    end
  end

  describe "extract_with_regex/2 - Rust" do
    test "extracts structs, enums, traits, impls, functions, constants", %{fixtures: dir} do
      symbols = TreeSitter.extract_with_regex(Path.join(dir, "lib.rs"), :rust)

      names = Enum.map(symbols, & &1.name)
      types = Enum.map(symbols, & &1.type)

      assert "Server" in names
      assert "Status" in names
      assert "Handler" in names
      assert "helper" in names
      assert "new" in names

      assert :struct in types
      assert :enum in types
      assert :trait in types
      assert :function in types
    end
  end

  describe "extract_with_regex/2 - Ruby" do
    test "extracts modules, classes, methods, attributes", %{fixtures: dir} do
      symbols = TreeSitter.extract_with_regex(Path.join(dir, "app.rb"), :ruby)

      names = Enum.map(symbols, & &1.name)
      types = Enum.map(symbols, & &1.type)

      assert "Authentication" in names
      assert "User" in names
      assert "Admin" in names
      assert "initialize" in names
      assert "admin?" in names
      assert "name" in names

      assert :module in types
      assert :class in types
      assert :function in types
      assert :attribute in types
    end
  end

  describe "extract_symbols/1 (integrated)" do
    test "extracts symbols and caches results", %{fixtures: dir} do
      path = Path.join(dir, "example.ex")

      # First call
      symbols1 = TreeSitter.extract_symbols(path)
      assert length(symbols1) > 0

      # Second call should use cache
      symbols2 = TreeSitter.extract_symbols(path)
      assert symbols1 == symbols2
    end

    test "returns empty list for nonexistent file" do
      assert TreeSitter.extract_symbols("/nonexistent/file.ex") == []
    end

    test "returns empty list for unsupported language", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "data.csv")
      File.write!(path, "a,b,c\n1,2,3\n")
      assert TreeSitter.extract_symbols(path) == []
    end
  end

  describe "cache management" do
    test "clear_cache empties the cache", %{fixtures: dir} do
      path = Path.join(dir, "example.ex")

      # Populate cache
      TreeSitter.extract_symbols(path)

      # Clear
      :ok = TreeSitter.clear_cache()

      # Cache should be empty (but extract_symbols still works via re-extraction)
      symbols = TreeSitter.extract_symbols(path)
      assert length(symbols) > 0
    end

    test "cache invalidates when file mtime changes", %{fixtures: dir} do
      path = Path.join(dir, "example.ex")

      # Populate cache
      symbols1 = TreeSitter.extract_symbols(path)

      # Touch the file to change mtime
      :timer.sleep(1100)
      File.write!(path, File.read!(path) <> "\n# added\n")

      # Should re-extract
      symbols2 = TreeSitter.extract_symbols(path)
      assert length(symbols2) >= length(symbols1)
    end
  end
end
