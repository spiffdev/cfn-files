# Example Stack
# BuildASGStack:
# :file_name: build-asg
# :condition_on_or_off: "on"
# :parameters:
# :master_parameters:
#   AsgSchedules: "on"
# :input_params_from_stack_outputs:
#   BuildRole: IAMStack
#   SecurityGroupAppInstance: SecurityGroupsStack
#   BuildStorageFS: BuildStaticStack
# :outputs:

def check_on_or_off(stack, details)
  # watch for weird yaml truthiness
  # yaml makes on = true for ruby so use quotes
  unless details[:condition_on_or_off] == 'on' || details[:condition_on_or_off] == 'off'
    return false
  end

  Parameter("#{stack}OnOrOff") do
    Type 'String'
    Default details[:condition_on_or_off]
    AllowedValues %[on off]
    Description "Choose on if you want #{stack} Stack to be deployed"
  end

  Condition("#{stack}OnOrOff", FnEquals(Ref("#{stack}OnOrOff"), 'on'))

  true
end

def stack_builder(stack, details, stack_parameters, s3_url)
  # clone so we don't stuff up params for other stacks
  cloned_stack_parameters = stack_parameters.clone

  # if :parameters then go ahead and merge that hash into cloned_stack_parameters
  if details[:parameters]
    details[:parameters].each do |k, v|
      cloned_stack_parameters[k] = v
    end
  end

  # if :condition_onoroff then add a Parameter to receive choice and make default the value provided (on|off)
  # if no onoroff then skip
  condition_on_or_off = check_on_or_off(stack, details)

  # if :input_params_from_stack_outputs then build inputs that are based on the outputs from another stack
  if details[:input_params_from_stack_outputs]
    details[:input_params_from_stack_outputs].each do |input, otherstack|
      cloned_stack_parameters[input] = FnGetAtt(otherstack, "Outputs.#{input}")
    end
  end

  # if :master_parameters then create new inbound parameter in this stack and add it as inbound parameter
  if details[:master_parameters]
    details[:master_parameters].each do |param, default|
      master_param = "#{stack}#{param}"
      Parameter(master_param) do
        Type 'String'
        Default default
      end
      cloned_stack_parameters[param] = Ref(master_param)
    end
  end

  # if :outputs: do output and export from this stack
  if details[:exports]
    details[:exports].each do |export|
      Output("#{stack}#{export}") {
        Value(FnGetAtt(stack, "Outputs.#{export}"))
        Export FnSub("${AWS::StackName}-#{stack}-#{export}")
        Condition "#{stack}OnOrOff" if condition_on_or_off
      }
    end
  end

  # if no :file_name then use stackname for file_name.  file_name is the name of the cfndsl file
  file_name = details[:file_name] ? details[:file_name] : stack

  # use s3_url as s3_url/file_name
  Resource(stack) do
    Type 'AWS::CloudFormation::Stack'
    Condition("#{stack}OnOrOff") if condition_on_or_off
    Property('TemplateURL', "#{s3_url}/#{file_name}.json")
    Property('Parameters', cloned_stack_parameters)
  end
end
