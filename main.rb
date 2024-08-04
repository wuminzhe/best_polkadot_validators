require 'scale_rb'
require 'logger'

def println(title, value, width = 23, pad_char = ' ')
  formatted_title = title.rjust(width, pad_char)
  puts "#{formatted_title}: #{value}"
end

# ScaleRb.logger.level = Logger::DEBUG

def validators(client, at, metadata)
  items = client.get_storage('Staking', 'Validators', block_hash: at, metadata:)

  items.map do |item|
    {
      account_id: "0x#{item[:storage_key][-64..]}",
      commission: item[:storage][:commission],
      blocked: item[:storage][:blocked]
    }
  end
end

# {
#   account_id: storage,
#   ...
# }
def get_exposures(client, era_index, at, metadata)
  # [
  #   {
  #     storage_key: "0x...",
  #     storage: {:total=>29668407726230783, :own=>10000000000000, :nominator_count=>183, :page_count=>1}
  #   },
  #   ...
  # ]
  storages = client.get_storage('Staking', 'ErasStakersOverview', [era_index], block_hash: at, metadata:) 

  storages.each_with_object({}) do |storage, acc|
    account_id = "0x#{storage[:storage_key][-64..]}"
    acc[account_id] = storage[:storage]
  end
end

def slashed_list(client, at, metadata)
  slashes = client.get_storage('Staking', 'SlashingSpans', block_hash: at, metadata:)

  slashes.each_with_object({}) do |storage, acc|
    account_id = "0x#{storage[:storage_key][-64..]}"
    acc[account_id] = true if storage[:storage][:last_nonzero_slash] != 0
  end
end

def get_identities(client, at, metadata)
  at = client.chain_getFinalizedHead
  storages = client.get_storage('Identity', 'IdentityOf', block_hash: at, metadata:)

  storages.each_with_object({}) do |storage, acc|
    account_id = "0x#{storage[:storage_key][-64..]}"
    acc[account_id] = storage[:storage]
  end
end

def super_of_list(client, at, metadata)
  storages = client.get_storage('Identity', 'SuperOf', block_hash: at, metadata:)

  storages.each_with_object({}) do |storage, acc|
    account_id = "0x#{storage[:storage_key][-64..]}"
    acc[account_id] = storage[:storage]
  end
end

def identity_display_name(account_id, identities)
  # [{:judgements=>[[0, "Reasonable"]], :deposit=>2008200000, :info=>{:display=>{:Raw11=>"0x5a7567204361706974616c"}, :legal=>"None", :web=>{:Raw22=>"0x68747470733a2f2f7a75676361706974616c2e636f6d"}, :matrix=>"None", :email=>{:Raw22=>"0x636f6e74616374407a75676361706974616c2e636f6d"}, :pgp_fingerprint=>"None", :image=>"None", :twitter=>"None", :github=>"None", :discord=>"None"}}, "None"
  identity = identities[account_id]

  display_name_code = identity&.first&.[](:info)&.[](:display)&.values&.first # "0x5a7567204361706974616c"
  display_name_code&._to_bytes&._to_utf8
end

def display_name_of(account_id, identities, super_of_list)
  self_name = identity_display_name(account_id, identities)
  return self_name if self_name

  # ["0x86f68361d0a346a62be267558e72dfb9e3b5a04adcc2c9e46fb7b9482f7c876f", {:Raw9=>"0x626572796c6c69756d"}]
  super_of = super_of_list[account_id]
  return if super_of.nil?

  self_name = if super_of[1] == 'None'
                'None'
              else
                super_of[1]&.values&.first&._to_bytes&._to_utf8
              end
  super_name = identity_display_name(super_of[0], identities)
  "#{super_name}/#{self_name}"
end

def add_display_name(validator, identities, super_of_list)
  validator[:display_name] =
    display_name_of(validator[:account_id], identities, super_of_list)
  validator
end

def add_address(validator)
  validator[:address] = ScaleRb::Address.encode(validator[:account_id], 0)
  validator
end

# Filter functions
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
  nominator_count = exposure[:nominator_count]
  nominator_count >= 220 # not 256
end

def slashed_before?(validator, slashed_list)
  slashed_list[validator[:account_id]] == true
end

def main
  url = 'https://polkadot-rpc.dwellir.com'
  # url = 'https://dot-rpc.stakeworld.io'

  client = ScaleRb::HttpClient.new(url)

  at = client.chain_getFinalizedHead
  println "head", at

  metadata = client.get_metadata(at)

  era = client.get_storage('Staking', 'CurrentEra', block_hash: at, metadata:)
  println 'era', era.inspect

  validators = validators(client, at, metadata)
  println "total validators count", validators.length

  exposures = get_exposures(client, era, at, metadata)
  println "active validators count", exposures.length

  slashed_list = slashed_list(client, at, metadata)

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
  println "result count", result.length
  
  people_client = ScaleRb::HttpClient.new('https://polkadot-people-rpc.polkadot.io')
  people_at = people_client.chain_getFinalizedHead
  people_metadata = people_client.get_metadata(people_at)

  identities = get_identities(people_client, people_at, people_metadata)
  super_of_list = super_of_list(people_client, people_at, people_metadata)

  result = result.map { |validator| add_display_name(validator, identities, super_of_list) }
                 .map { |validator| add_address(validator) }
                 .map { |validator| validator.slice(:display_name, :commission, :address, :account_id) }
                 .sort { |a, b| a[:commission] <=> b[:commission] }

  # save result to file
  filename = "./result/#{Time.now.strftime('%Y%m%d%H%M%S')}-#{at}.json"
  File.open(filename, 'w') do |f|
    f.write(JSON.pretty_generate(result))
  end
end

main
