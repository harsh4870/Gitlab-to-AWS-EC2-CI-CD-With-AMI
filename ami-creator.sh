#!/bin/bash
set -e

#Gitlab CI file invoke this file keep it with .gitlab-ci.yaml

yes | ssh-keygen -b 2048 -t rsa -f /tmp/sshkey -q -N "" > /dev/null

# Request spot instance
export SPOT_REQUEST_ID=`aws ec2 request-spot-instances \
  --launch-specification file://build/launch-spec.json \
  --query SpotInstanceRequests[0].SpotInstanceRequestId \
  --output text`
echo Spot instance request ID is $SPOT_REQUEST_ID, waiting for instance

for i in {0..10}
do
  if [ $i -eq 10 ]
  then
    echo Tried waiting 10 times for a spot instance, just cancelling it
    aws ec2 cancel-spot-instance-requests --spot-instance-request-ids $SPOT_REQUEST_ID > /dev/null
    exit 1
  fi
  export SPOT_INSTANCE_STATUS=`aws ec2 describe-spot-instance-requests \
  --spot-instance-request-ids $SPOT_REQUEST_ID \
  --query SpotInstanceRequests[0].Status.Code \
  --output text`
  echo Spot instance request status: $SPOT_INSTANCE_STATUS
  if [ "$SPOT_INSTANCE_STATUS" = "fulfilled" ]
  then
    break
  fi
  echo Sleeping for a little
  sleep 3
done

# Get the instance ID
export INSTANCE_ID=`aws ec2 describe-spot-instance-requests \
  --spot-instance-request-ids $SPOT_REQUEST_ID \
  --query SpotInstanceRequests[0].InstanceId \
  --output text`

echo $INSTANCE_ID > ./build/build_instance_id
echo Alright, we snagged a bargain with instance $INSTANCE_ID
export INSTANCE_DESCRIPTION=`aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID`

export INSTANCE_AZ=`echo $INSTANCE_DESCRIPTION | jq -r .Reservations[0].Instances[0].Placement.AvailabilityZone`
export INSTANCE_IP=`echo $INSTANCE_DESCRIPTION | jq -r .Reservations[0].Instances[0].PublicIpAddress`

sleep 10
echo Dropping our key onto the box
echo Details of instance check status, $INSTANCE_DESCRIPTION

# Wait for a bit
sleep 20

aws ec2-instance-connect send-ssh-public-key \
  --instance-id $INSTANCE_ID \
  --instance-os-user ec2-user \
  --availability-zone $INSTANCE_AZ \
  --ssh-public-key file:///tmp/sshkey.pub
sleep 20

#Setting Nginx config, Variables for application based on Main & Dev Git branch
ssh -o "StrictHostKeyChecking no" \
    -i /tmp/sshkey ec2-user@$INSTANCE_IP \
    "sudo yum install git -y && curl -sL https://rpm.nodesource.com/setup_16.x | sudo -E bash - && sudo yum install nodejs -y && sudo mkdir /var/log/nginx && sudo amazon-linux-extras install nginx1 -y && sudo yum install awslogs -y && sudo systemctl start awslogsd && sudo systemctl enable awslogsd.service && sudo service nginx start && sudo systemctl start nginx && sudo systemctl enable nginx && git clone https://$USER_NAME:$GIT_ACCESS_TOKEN@gitlab.com/$CI_PROJECT_NAMESPACE/$CI_PROJECT_NAME.git && cd $CI_PROJECT_NAME && npm install && sudo npm install pm2 -g && export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID && export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY && sudo rm /etc/nginx/nginx.conf && aws s3 cp s3://ami-env-secret-config/nginx.conf ./ && sudo cp nginx.conf /etc/nginx/nginx.conf && sudo service nginx restart && if [ $CI_COMMIT_BRANCH == main ]; then aws s3 cp s3://ami-env-secret-config/.env-prod ./; else aws s3 cp s3://ami-env-secret-config/.env-test ./; fi"

#Once application set will take snapshot
echo Creating image
export AMI_ID=`aws ec2 create-image \
  --instance-id $INSTANCE_ID \
  --name ami-$CI_COMMIT_BRANCH-$CI_COMMIT_SHORT_SHA \
  --query ImageId \
  --output text`
echo Waiting for $AMI_ID to create
export AMI_STATE=`aws ec2 describe-images \
  --image-ids $AMI_ID \
  --query Images[0].State \
  --output text`
while [ "$AMI_STATE" = "pending" ]
do
  echo Still waiting on that image
  sleep 30
  export AMI_STATE=`aws ec2 describe-images \
    --image-ids $AMI_ID \
    --query Images[0].State \
    --output text`
done
echo Shutting $INSTANCE_ID down
aws ec2 terminate-instances --instance-ids $INSTANCE_ID > /dev/null
if [ "$AMI_STATE" = "failed" ]
then
  echo Failed to create image:
  aws ec2 describe-images --image-ids $AMI_ID --query Images[0].StateReason.Message --output text
  exit 1
fi
echo $AMI_ID > build/ami_id
