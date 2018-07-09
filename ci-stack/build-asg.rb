require_relative '../lib/shared'

CloudFormation do
  version = external_parameters[:version]
  application_name = external_parameters[:application_name]
  project = external_parameters[:project]
  availability_zones = external_parameters[:availability_zones]
  version = external_parameters.fetch(:version)
  account_maps = external_parameters[:account_maps]
  app_settings = external_parameters[:app_settings]
  subnets = external_parameters[:stacks]['BuildASGStack'][:subnets]

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

  Mapping('AccountSettings', account_maps)
  Mapping('AppSettings', app_settings)

  default_parameters.each { |parameter| Parameter(parameter) { Type 'String' } }

  %w[VPC ECSCluster BuildRole SecurityGroupAppInstance
     BuildStorageFS].each { |parameter| Parameter(parameter) { Type 'String' } }

  Parameter('AsgSchedules') {
    Type 'String'
    AllowedValues ['on', 'off']
    Default 'on'
  }

  Condition('AsgSchedules', FnEquals(Ref('AsgSchedules'), 'on'))

  availability_zones.each do |az|
    Parameter("PrivateSubnet#{az}") { Type 'String' }
  end

  InstanceProfile('InstanceProfile') {
    Path '/'
    Roles [Ref('BuildRole')]
  }

  LaunchConfiguration(:LaunchConfig) {
    ImageId FnFindInMap('AppSettings', Ref('Environment'), 'BuildInstanceImageId')
    IamInstanceProfile Ref('InstanceProfile')
    KeyName FnFindInMap('AccountSettings', Ref('AWS::AccountId'), 'Ec2KeyPair')
    SecurityGroups [Ref('SecurityGroupAppInstance')]
    InstanceType FnFindInMap('AppSettings', Ref('Environment'), 'MasterSpotInstanceType')
    Property('SpotPrice', FnFindInMap('AppSettings', Ref('Environment'), 'MasterSpotPrice'))
    Property('BlockDeviceMappings', [{ DeviceName: '/dev/xvda', Ebs: { VolumeSize: 20 } },
                                     { DeviceName: '/dev/xvdcz', Ebs: { VolumeSize: 50, VolumeType: 'gp2' } }])
    UserData FnBase64(FnJoin('', [
      "#!/bin/bash\n",
      "echo ECS_CLUSTER=", Ref('ECSCluster'), " >> /etc/ecs/ecs.config\n",
      "echo ECS_INSTANCE_ATTRIBUTES='{\"BuildGroup\": \"master\"}' >> /etc/ecs/ecs.config\n",
      "yum update -y\n",
      "yum install -y python-pip awslogs nfs-utils jq\n",
      "python-pip install --upgrade awscli\n",
      "curl https://amazon-ssm-", Ref("AWS::Region"),".s3.amazonaws.com/latest/linux_amd64/amazon-ssm-agent.rpm -o /tmp/amazon-ssm-agent.rpm\n",
      "yum install -y /tmp/amazon-ssm-agent.rpm\n",
      "curl -L https://github.com/barnybug/cli53/releases/download/0.8.12/cli53-linux-amd64 -o /usr/local/bin/cli53\n",
      "chmod a+x /usr/local/bin/cli53\n",
      "FILE_SYSTEM_ID=", Ref('BuildStorageFS'), "\n",
      "REGION=", Ref('AWS::Region'), "\n",
      "MOUNT_POINT=/mnt/efs\n",
      "mkdir -p ${MOUNT_POINT}\n",
      "chown ec2-user:ec2-user ${MOUNT_POINT}\n",
      "echo ${FILE_SYSTEM_ID}.efs.${REGION}.amazonaws.com:/ ${MOUNT_POINT} nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev 0 0 >> /etc/fstab\n",
      "mount -a -t nfs4\n",
      "df -t\n",
      "mkdir -p /mnt/efs/data \n",
      "mkdir -p /mnt/efs/data/jenkins; chown -R 1000:1000 /mnt/efs/data/jenkins\n",
      "stop ecs\n",
      "service docker stop\n",
      "service docker start\n",
      "start ecs\n",
      "$(/usr/local/bin/aws ecr get-login --no-include-email --region ", Ref("AWS::Region") ,")\n",
      "cat /var/log/ecs/ecs-agent.log\n",
      "cat /var/log/ecs/ecs-init.log.*\n",
      "yum -y erase ntp || true\n",
      "sleep 10\n",
      "sudo yum -y install chrony\n",
      "sleep 10\n",
      "chkconfig chronyd on || true\n",
      "sudo service chronyd start || true\n",
      "export DNS_NAME=", FnJoin('', [ FnFindInMap('AccountSettings', Ref('AWS::AccountId'),'PrivateDNSDomain'), '.'])), "\n",
      "export LOCAL_IP=`curl http://169.254.169.254/latest/meta-data/public-ipv4`\n",
      "export ZONE=`aws route53 list-hosted-zones | jq --arg dns_name ${DNS_NAME} -r '.HostedZones[] |   select(.Name == $dns_name and .Config.PrivateZone == true) | .Id | ltrimstr(\"/hostedzone/\")'`\n",
      "/usr/local/bin/cli53 rrcreate $ZONE jenkins A $LOCAL_IP --replace --ttl 60"
    ]))
  }

  AutoScalingGroup('BuildAutoScaleGroup') {
    UpdatePolicy('AutoScalingRollingUpdate', {
      'MinInstancesInService' => '0',
      'MaxBatchSize'          => '1',
    })
    LaunchConfigurationName Ref('LaunchConfig')
    HealthCheckGracePeriod '500'
    MinSize 1
    MaxSize 1
    DesiredCapacity 1
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
        'GroupTotalInstances'
      ]
    }])
    VPCZoneIdentifier subnet_list
    Property('Tags', asg_default_tags)
  }

  Resource('ScheduledActionUp') {
    Condition 'AsgSchedules'
    Type 'AWS::AutoScaling::ScheduledAction'
    Property('AutoScalingGroupName', Ref('BuildAutoScaleGroup'))
    Property('MinSize','1')
    Property('MaxSize', '1')
    Property('DesiredCapacity', '1')
    Property('Recurrence', '0 20 * * 0-4')
  }

  Resource('ScheduledActionDown') {
    Condition 'AsgSchedules'
    Type 'AWS::AutoScaling::ScheduledAction'
    Property('AutoScalingGroupName', Ref('BuildAutoScaleGroup'))
    Property('MinSize','0')
    Property('MaxSize', '0')
    Property('DesiredCapacity', '0')
    Property('Recurrence', '0 10 * * *')
  }

end
