#!/bin/bash
set -e

#Trigger the AMI deployment to Development & Prod EC2 Instances

export AMI_ID=$(aws ec2 describe-images --owners self --filters "Name=name,Values=ami-$CI_COMMIT_BRANCH-$CI_COMMIT_SHORT_SHA" --query Images[0].ImageId --output text)

#Based on branch Main or Dev set the Launch & Autoscaling vars
#So accordingly AMI will get updated to target groups
if [ $CI_COMMIT_BRANCH == main ]; then export LAUNCH_TEMPLATE=$PROD_LAUNCH_TEMPLATE && export ASG_GROUP=$PROD_ASG_GROUP; else export LAUNCH_TEMPLATE=$TEST_LAUNCH_TEMPLATE && export ASG_GROUP=$TEST_ASG_GROUP; fi

echo LAUNCH_TEMPLATE=$LAUNCH_TEMPLATE && echo BRANCH=$CI_COMMIT_BRANCH && echo AMI_ID=$AMI_ID

#Create launch template new version with AMI created
aws ec2 create-launch-template-version --launch-template-id $LAUNCH_TEMPLATE --version-description $CI_COMMIT_SHORT_SHA --source-version $SOURCE_TEMPLATE_VERSION --launch-template-data ImageId=$AMI_ID

aws autoscaling update-auto-scaling-group --auto-scaling-group-name $ASG_GROUP --desired-capacity 2 && sleep 10

aws autoscaling update-auto-scaling-group --auto-scaling-group-name $ASG_GROUP --launch-template LaunchTemplateId=$LAUNCH_TEMPLATE,Version='$Latest'

echo "Scaling up done...! Rolling out the new AMI"
