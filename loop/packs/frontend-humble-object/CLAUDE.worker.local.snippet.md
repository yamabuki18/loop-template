FRONTEND TESTING (humble-object pack): put logic in pure functions/presenters/hooks with
co-located unit tests; keep views thin and untested. NEVER create E2E suites (e2e/, cypress/,
*.e2e.*, *.cy.*, playwright configs) — a harness guard blocks them and the gate re-checks.
Interactive browser verification while developing is fine; committing it as a suite is not.
