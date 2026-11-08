--- `:Vergil pick` arguments: a tab, or `attach`/`mention` for Files in that
--- mode. Kept apart from the picker so the `<Plug>` maps and command
--- completion, set up at startup, don't load it.
return { "all", "attach", "mention", "skills", "changed", "branches", "commits" }
