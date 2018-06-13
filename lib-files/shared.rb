def get_aws_tags(tags_map)
  tags = []

  tags_map.each do |tag|
    tags << { Key: tag[:key], Value: Ref(tag[:ref]) }
  end
  
  tags
end

# given an array of tags
#  search that array and replace hashes
#  add any that don't match
def tags_merger(orig, new)
  return_array = []
  orig.each { |x| return_array << x.clone }

  new.each do |a|
    key_found = false
    return_array.each do |r|
      if a[:Key] == r[:Key]
        r[:Value] = a[:Value]
        key_found = true
      end
      break if key_found
    end
    return_array << a unless key_found
  end

  return_array
end

# given and array of tags
#   search the array for the name and replace or add
def add_new_name_to_tags(orig, tag_name)
  return_array = []
  
  # sort of deep clone
  orig.each {|x| return_array << x.clone}

  name_key_found = false

  return_array.each do |r|
    if r[:Key] == 'Name'
      r[:Value] = tag_name
      name_key_found = true
    end
    break if name_key_found
  end

  unless name_key_found
    return_array << { Key: 'Name', Value: tag_name}
  end

  return_array
end

# early days for this one
# this is to replace name cidrs in config maps with actual cidr - either real or fnjoins
def cidrator(cidr, options = {})
  cidr_prefix = options[:cidr_prefix] || '.0.0/16'
  cidr = case cidr
         when 'local_subnet' then FnJoin('', [Ref('CIDRPrefix'), cidr_prefix])
         when 'InboundExternalIPRange' then FnFindInMap('NetworkSettings', Ref('Environment'), 'InboundExternalIPRange')
         else cidr
         end
end
