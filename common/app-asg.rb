require_relative '../lib/shared'

CloudFormation do
  version = external_parameters[:version]
  application_name = external_parameters[:application_name]
  project = external_parameters[:project]
  availability_zones = external_parameters[:availability_zones]
  version = external_parameters.fetch(:version)
  account_maps = external_parameters[:account_maps]
  app_settings = external_parameters[:app_settings]

  default_tags =  render_aws_tags(external_parameters[:default_tags])

  asg_default_tags = [
    {Key: 'Name', Value: FnSub("${MasterStackName}-build-app-asg"), PropagateAtLaunch: true},
    {Key: 'Stack', Value: Ref('MasterStackName'), PropagateAtLaunch: true},
    {Key: 'Environment', Value: Ref('Environment'), PropagateAtLaunch: true},
  ]

  subnet_list = []
  availability_zones.each { |zone| subnet_list << Ref("PrivateSubnet#{zone}") }

  Metadata(
    Template: 'build-asg',
    Description: 'This template sets up the asg and related things for running build containers including jenkins',
    Project: project,
    Application: application_name,
    Version: version
  )

  AWSTemplateFormatVersion '2010-09-09'
  Description "#{project}/#{application_name} - App - #{version}"

  default_parameters.each { |parameter| Parameter(parameter) { Type 'String' } }

  %w[VPC ECSCluster ECSAppInstanceRole SecurityGroupAppInstance AppRoleName].each { |parameter| Parameter(parameter) { Type 'String' } }

  availability_zones.each do |az|
    Parameter("PrivateSubnet#{az}") { Type 'String' }
  end

  Parameter('AsgSchedules') {
    Type 'String'
    AllowedValues %w[on off]
    Default 'on'
  }

  Mapping('AccountSettings', account_maps)
  Mapping('AppSettings', app_settings)

  Condition('AsgSchedules', FnEquals(Ref('AsgSchedules'), 'on'))

  Condition('Production', FnEquals(Ref('Environment'), 'production'))

  InstanceProfile('InstanceProfile') {
    Path '/'
    Roles [ Ref('ECSAppInstanceRole') ]
  }

  LaunchConfiguration(:LaunchConfig) {
    ImageId FnFindInMap('AppSettings', Ref('Environment'), 'BuildInstanceImageId')
    IamInstanceProfile Ref('InstanceProfile')
    KeyName FnFindInMap('AccountSettings', Ref('AWS::AccountId'), 'Ec2KeyPair')
    SecurityGroups [ Ref('SecurityGroupAppInstance')]
    InstanceType FnFindInMap('AppSettings', Ref('Environment'), 'BuildInstanceType')
    Property('BlockDeviceMappings', [{ DeviceName: '/dev/xvda', Ebs: { VolumeSize: 30 } },
                                     { DeviceName: '/dev/xvdcz', Ebs: { VolumeSize: 50, VolumeType: 'gp2' } }])
    UserData FnBase64(FnJoin('',[
      "#!/bin/bash\n",
      "echo ECS_CLUSTER=", Ref('ECSCluster'), " >> /etc/ecs/ecs.config\n",
      "echo ECS_INSTANCE_ATTRIBUTES='{\"DeployGroup\": \"normal\"}' >> /etc/ecs/ecs.config\n",
      "stop ecs\n",
      "start ecs\n",
      "curl https://amazon-ssm-", Ref("AWS::Region"),".s3.amazonaws.com/latest/linux_amd64/amazon-ssm-agent.rpm -o /tmp/amazon-ssm-agent.rpm\n",
      "yum install -y /tmp/amazon-ssm-agent.rpm\n",
      "yum install -y awslogs\n",
      "yum -y erase ntp || true\n",
      "sleep 10\n",
      "sudo yum -y install chrony\n",
      "sleep 10\n",
      "chkconfig chronyd on || true\n",
      "sudo service chronyd start || true\n",
      "cat /var/log/ecs/ecs-agent.log\n",
      "cat /var/log/ecs/ecs-init.log.*"
    ]))
  }

  AutoScalingGroup('BuildAutoScaleGroup') {
    UpdatePolicy('AutoScalingRollingUpdate', {
      'MinInstancesInService' => '0',
      'MaxBatchSize'          => '1',
    })
    LaunchConfigurationName Ref('LaunchConfig')
    HealthCheckGracePeriod '500'
    MinSize FnIf('Production', 3, 1)
    MaxSize FnIf('Production', 3, 1)
    DesiredCapacity FnIf('Production', 3, 1)
    Property('MetricsCollection', [{
      Granularity: '1Minute',
      Metrics: [
        'GroupDesiredCapacity',
        'GroupInServiceInstances',
        'GroupMaxSize',
        'GroupMinSize',
        'GroupPendingInstances',
        'GroupStandbyInstances',
        'GroupTerminatingInstances',
        'GroupTotalInstances',
      ]
    }])
    VPCZoneIdentifier subnet_list
    Property('Tags', asg_default_tags)
  }

  Resource("ScheduledActionUp") {
    Condition 'AsgSchedules'
    Type 'AWS::AutoScaling::ScheduledAction'
    Property('AutoScalingGroupName', Ref('BuildAutoScaleGroup'))
    Property('MinSize','1')
    Property('MaxSize', '1')
    Property('DesiredCapacity', '1')
    Property('Recurrence', '0 20 * * 0-4')
  }

  Resource("ScheduledActionDown") {
    Condition 'AsgSchedules'
    Type 'AWS::AutoScaling::ScheduledAction'
    Property('AutoScalingGroupName', Ref('BuildAutoScaleGroup'))
    Property('MinSize','0')
    Property('MaxSize', '0')
    Property('DesiredCapacity', '0')
    Property('Recurrence', '0 10 * * *')
  }

end