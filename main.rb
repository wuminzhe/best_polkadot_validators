require 'scale_rb'

def validators(url, metadata, at = nil)
  # TODO: scale_rb: remove metadata
  items = ScaleRb::HttpClient.get_storage3(url, metadata, 'staking', 'validators', at: at)

  items.map do |item|
    {
      account_id: "0x#{item[:storage_key][-64..]}",
      commission: item[:storage][:commission],
      blocked: item[:storage][:blocked]
    }
  end
end

def blocked_nominations?(validator)
  validator[:blocked] == true
end

def unhealthy_commission?(validator)
  commission = validator[:commission]
  # commission == 0 || commission > 50_000_000
  commission > 50_000_000
end

def unhealthy_own_stake?(exposure)
  own_stake = exposure[:own]
  own_stake < 10_000 * 10**9
end

def over_subscribed?(exposure)
  nominator_count = exposure[:others].length
  nominator_count >= 220 # not 256
end

# {
#   account_id: storage,
#   ...
# }
def get_exposures(url, metadata, era_index, at)
  # [
  #   {
  #     storage_key: "0x...",
  #     storage: {
  #       :total=>24562033284196687,
  #       :own=>50003254094151,
  #       :others=>[
  #         {:who=>"0xc0a4491a8414abdab62f35f94dd43e318a72802ffb203e86df1dd6bcdc9b9458", :value=>12364417353224},
  #         {:who=>"0x4e971e23c90ddb297e075629324720fcd556a20ce6c38bb1cafc38e048c36992", :value=>6600000000000},
  #         {:who=>"0xf2838189b9033632facd4a593ddb4cbb9fcc6eeb82b5c9ceacee56791f10f92c", :value=>5902280178930},
  #         {:who=>"0x83bf40ac1231b8b9b539abead87569ae512edd874c710cd249afecab1093cf03", :value=>24487163332570382}
  #       ]
  #     }
  #   },
  #   ...
  # ]
  storages = ScaleRb::HttpClient.get_storage3(
    url, metadata, 'staking', 'eras_stakers',
    key_part1: era_index.to_s, # TODO: scale_rb: to_s
    at: at
  )

  storages.each_with_object({}) do |storage, acc|
    account_id = "0x#{storage[:storage_key][-64..]}"
    acc[account_id] = storage[:storage]
  end
end

def slashed_list(url, metadata, at)
  slashes = ScaleRb::HttpClient.get_storage3(
    url, metadata, 'staking', 'slashing_spans',
    at: at
  )

  slashes.each_with_object({}) do |storage, acc|
    account_id = "0x#{storage[:storage_key][-64..]}"
    acc[account_id] = true if storage[:storage][:last_nonzero_slash] != 0
  end
end

def identities(url, metadata, at)
  storages = ScaleRb::HttpClient.get_storage3(
    url, metadata, 'identity', 'identity_of',
    at: at
  )
  storages.each_with_object({}) do |storage, acc|
    account_id = "0x#{storage[:storage_key][-64..]}"
    acc[account_id] = storage[:storage]
  end
end

def super_of_list(url, metadata, at)
  storages = ScaleRb::HttpClient.get_storage3(
    url, metadata, 'identity', 'super_of',
    at: at
  )
  storages.each_with_object({}) do |storage, acc|
    account_id = "0x#{storage[:storage_key][-64..]}"
    acc[account_id] = storage[:storage]
  end
end

def identity_display_name(account_id, identities)
  identity = identities[account_id]

  display_name_code = identity&.[](:info)&.[](:display)&.values&.first
  display_name_code&.to_bytes&.to_utf8
end

def display_name_of(account_id, identities, super_of_list)
  self_name = identity_display_name(account_id, identities)
  return self_name if self_name

  super_of = super_of_list[account_id]
  return if super_of.nil?

  # `super_of` example:
  #   ["0x86f68361d0a346a62be267558e72dfb9e3b5a04adcc2c9e46fb7b9482f7c876f", {:Raw9=>"0x626572796c6c69756d"}]
  self_name = super_of[1]&.values&.first&.to_bytes&.to_utf8
  super_name = identity_display_name(super_of[0], identities)
  "#{super_name}/#{self_name}"
end

def add_display_name(validator, identities, super_of_list)
  validator[:display_name] =
    display_name_of(validator[:account_id], identities, super_of_list)
  validator
end

def add_address(validator)
  validator[:address] = Address.encode(validator[:account_id], 0)
  validator
end

def slashed_before?(validator, slashed_list)
  slashed_list[validator[:account_id]] == true
end

def main
  # url = 'https://polkadot-rpc.dwellir.com'
  url = 'https://dot-rpc.stakeworld.io'

  at = ScaleRb::HttpClient.chain_getFinalizedHead(url)
  puts "head: #{at}"
  metadata = ScaleRb::HttpClient.get_metadata_cached(url, at: at, dir: './metadata')

  era_index = ScaleRb::HttpClient.get_storage3(url, metadata, 'staking', 'active_era', at: at)[:index]
  puts "era: #{era_index}"

  validators = validators(url, metadata, at)
  puts "total validators count: #{validators.length}"

  exposures = get_exposures(url, metadata, era_index, at)
  puts "active validators count: #{exposures.length}"

  slashed_list = slashed_list(url, metadata, at)

  # apply filter
  result = validators.delete_if do |validator|
    account_id = validator[:account_id]

    exposures[account_id].nil? || # not active
      blocked_nominations?(validator) ||
      unhealthy_commission?(validator) ||
      over_subscribed?(exposures[account_id]) ||
      unhealthy_own_stake?(exposures[account_id]) ||
      slashed_before?(validator, slashed_list)
  end

  # add display name and address
  puts "result count: #{result.length}"
  identities = identities(url, metadata, at)
  super_of_list = super_of_list(url, metadata, at)
  result = result.map { |validator| add_display_name(validator, identities, super_of_list) }
                 .map { |validator| add_address(validator) }
                 .map { |validator| validator.slice(:display_name, :commission, :address, :account_id) }
                 .sort { |a, b| a[:commission] <=> b[:commission] }

  # save result to file
  filename = "./result/#{Time.now.strftime('%Y%M%d')}-#{at}.json"
  File.open(filename, 'w') do |f|
    f.write(JSON.pretty_generate(result))
  end
end

main
