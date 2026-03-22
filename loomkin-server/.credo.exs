%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      checks: %{
        disabled: [
          # Pre-existing widespread patterns — not enforced on existing code
          {Credo.Check.Design.AliasUsage, false},
          {Credo.Check.Readability.LargeNumbers, false},
          {Credo.Check.Readability.ModuleDoc, false},
          {Credo.Check.Readability.PredicateFunctionNames, false},
          {Credo.Check.Readability.WithSingleClause, false},
          {Credo.Check.Refactor.CondStatements, false},
          {Credo.Check.Refactor.CyclomaticComplexity, false},
          {Credo.Check.Refactor.FunctionArity, false},
          {Credo.Check.Refactor.MapJoin, false},
          {Credo.Check.Refactor.NegatedConditionsWithElse, false},
          {Credo.Check.Refactor.Nesting, false},
          {Credo.Check.Refactor.RejectReject, false},
          {Credo.Check.Refactor.UnlessWithElse, false},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, false},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, false},
          # Agent GenServer naturally has complex state (33 fields); refactor tracked in backlog
          {Credo.Check.Warning.StructFieldAmount, false}
        ]
      }
    }
  ]
}
