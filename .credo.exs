%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      checks: %{
        enabled: [
          # Relax nesting from 2 to 3 — Mnesia case-matching inherently nests
          {Credo.Check.Refactor.Nesting, max_nesting: 3},
          # Relax complexity from 9 to 15 — AI state machines and CLI dispatch are branchy
          {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 15}
        ],
        disabled: []
      }
    }
  ]
}
