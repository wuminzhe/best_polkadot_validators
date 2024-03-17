# best_polkadot_validators

This is a script(ruby lang) to help to get the best polkadot validators using the rules below:

```ruby
result = validators.delete_if do |validator|
  account_id = validator[:account_id]

  exposures[account_id].nil? || # not active
    blocked_nominations?(validator) ||
    unhealthy_commission?(validator) ||
    over_subscribed?(exposures[account_id]) ||
    unhealthy_own_stake?(exposures[account_id]) ||
    slashed_before?(validator, slashed_list)
end
```

The result is sorted by commission asc.

## Usage
```bash
# Install deps
bundle install

# Run
bundle exec ruby main.rb
```

* See result in the `result` folder.
* The script will fetch the latest metadata automatically.
