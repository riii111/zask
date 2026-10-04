# Test Data

`synthetic.json` is the minimal shared fixture for config parsing and validation
coverage. Add new config validation cases there or in similarly small synthetic
fixtures. `synthetic.jsonc` is the same config with comments and `$schema`;
keep the two in sync.

`showcase/receipt-lab` is a demo asset for screenshots and local behavior
checks. Keep it production-like and public-safe, but do not use its breadth as
the default place for new config validation coverage.
