#!/bin/bash
set -eux
region="us-east-1"
UtilizationThreshold="1.0"
# Function to fetch available RDS instance classes
fetch_available_rds_instance_classes() {
    local rds_instance_engine=$1
    aws rds describe-orderable-db-instance-options --engine $rds_instance_engine --query 'OrderableDBInstanceOptions[*].DBInstanceClass' --output json | jq -r '.[]' | sed -e 'y/\t/\n/' | sort | uniq
}

# Function to fetch hourly on-demand cost for an RDS instance class
fetch_rds_instance_class_cost() {
    local instance_class=$1
    aws pricing --region us-east-1 get-products \
        --service-code AmazonRDS \
        --filters 'Type=TERM_MATCH,Field=instanceType,Value='"$instance_class" Type=TERM_MATCH,Field=regionCode,Value=${region} \
        --query 'PriceList[0]' | jq -r > json
    cat json | jq -r .terms.OnDemand[].priceDimensions[].pricePerUnit.USD

}

fetch_rds_instance_current_mem() {
    local instance_class=$1
    aws pricing --region us-east-1 get-products \
        --service-code AmazonRDS \
        --filters 'Type=TERM_MATCH,Field=instanceType,Value='"$instance_class" Type=TERM_MATCH,Field=regionCode,Value=${region} \
        --query 'PriceList[0]' | jq -r > json
    memory=$(cat json | jq -r .product.attributes.memory | sed "s/\bGiB\b//g")

    echo "scale=0; ${memory} / 1" | bc

}

# Function to fetch CloudWatch metric statistics
fetch_cloudwatch_metric() {
    local resource_id=$1
    local metric_name=$2
    local namespace=$3

    local start_time=$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%SZ')
    local end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    Bytes=$(aws cloudwatch get-metric-statistics \
        --namespace "$namespace" \
        --metric-name "$metric_name" \
        --dimensions "Name=DBInstanceIdentifier,Value=$resource_id" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --period 86400 \
        --statistics Maximum \
        --output json  | jq -r .Datapoints | jq 'map(select(.Unit == "Bytes") .Maximum) | max')

     bytestogb=1000000000
     z=$((Bytes / bytestogb))
     echo $z

}

# Function to calculate percentage utilization
calculate_percentage_utilization() {
    local current_value=$1
    local total_value=$2

    if [ $total_value -eq 0 ]; then
        echo 0
    else
        echo "scale=2; ($current_value / $total_value)" | bc
    fi
}


# Function to calculate expected final utilization after resizing
calculate_expected_final_utilization() {
    local current_memory_used=$1
    local new_instance_type=$2

    final_memory_allocated=$(fetch_rds_instance_current_mem "$new_instance_type")

    # You would need to customize this logic based on how the new instance type affects utilization
    # For simplicity, let's assume a linear relationship for demonstration purposes
    #local utilization_factor=0.8  # Adjust this factor based on your specific scenario

    echo "scale=2; $current_memory_used / $final_memory_allocated" | bc
}

# Output file
output_file="recommendations.csv"

# Fetch existing RDS instances
rds_instance_ids=($(aws rds describe-db-instances --query 'DBInstances[*].DBInstanceIdentifier' --output json | jq -r '.[]'))

# Fetch available EC2 instance types
#ec2_available_instance_types=($(fetch_available_ec2_instance_types))

# Create CSV file and write header
echo "Resource, Current Instance Type, Current Allocated Mem, Current Utilization, Current Hourly Cost, Target Instance Type, Target Allocated Memory, Expected Final Utilization, Final Hourly Cost (USD), Savings, Annual Savings" > "$output_file"

# RDS Recommendations
for instance_id in "${rds_instance_ids[@]}"; do
    current_rds_instance_engine=($(aws rds describe-db-instances --db-instance-identifier $instance_id --query 'DBInstances[*].Engine' --output json | jq -r '.[]'))
    current_rds_instance_class=($(aws rds describe-db-instances --db-instance-identifier $instance_id --query 'DBInstances[*].DBInstanceClass' --output json | jq -r '.[]'))
    if [ $current_rds_instance_class == "db.serverless" ]
    then
      echo "cluster of type db.serverless is skipped"
      echo "RDS,$instance_id,$current_rds_instance_class,0,0,0,$current_rds_instance_class,0,0,0,0,0" >> "$output_file"
    else
      # Fetch available RDS instance classes
      current_hourly_cost=$(fetch_rds_instance_class_cost "$current_rds_instance_class")
      rds_available_instance_classes=($(fetch_available_rds_instance_classes "$current_rds_instance_engine"))

      current_memory_free=$(fetch_cloudwatch_metric "$instance_id" "FreeableMemory" "AWS/RDS")
      available_instance_classes=("${rds_available_instance_classes[@]}")

      current_memory_allocated=$(fetch_rds_instance_current_mem "$current_rds_instance_class")
      current_memory_used=$((current_memory_allocated - current_memory_free))
      current_memory_utilization=$(calculate_percentage_utilization "$current_memory_used" "$current_memory_allocated")
      hourly_cost=$(fetch_rds_instance_class_cost "$current_rds_instance_class")
      echo "RDS Instance ID: $instance_id"
      echo "Current Memory Utilization: $current_memory_utilization"
      echo "Current Instance Class: $current_memory_utilization"
      echo "Current Hourly Cost: $current_hourly_cost"
      for instance_class in "${available_instance_classes[@]}"; do
         final_memory_allocated=$(fetch_rds_instance_current_mem "$instance_class")
         echo $instance_class
         echo $final_memory_allocated
         echo $current_memory_allocated
         if [ $instance_class == "db.serverless" ] || [ $final_memory_allocated -gt $current_memory_allocated ]
         then
           echo "either a db.serverless or bigger instance class"
         else
           suggested_utilization_candidate=$(calculate_percentage_utilization "$current_memory_used" "$final_memory_allocated")
           #if [ $(echo "$suggested_utilization_candidate -le $current_memory_utilization" | bc) -eq 1 ]; then
           echo "123"
           if (( $(bc <<< "$suggested_utilization_candidate <  $current_memory_utilization"))); then
             echo "456"
             echo "$instance_class is skipped as utilization is $suggested_utilization_candidate, i.e less then current utlization $current_memory_utilization"
           #elif [ $(echo "$suggested_utilization_candidate  -ge $UtilizationThreshold" | bc) -eq 1 ]; then
           echo "789"
           elif (( $(bc <<< "$suggested_utilization_candidate >=  $UtilizationThreshold"))); then
             echo "000"
             echo "$instance_class is skipped as utilization is $suggested_utilization_candidate, i.e greater then $UtilizationThreshold"
           else
             # Fetch hourly on-demand cost
             hourly_cost=$(fetch_rds_instance_class_cost "$instance_class")
             echo "RDS Recommendation:"
             echo "RDS Instance ID: $instance_id"
             echo "Current Memory Utilization: $current_memory_utilization"
             echo "Suggested Instance Class: $current_memory_utilization"
             echo "Expected Final Memory Utilization: suggested_utilization_candidate"  # Assuming target utilization is 60%
             echo "Hourly Cost: $hourly_cost"
             echo
             savings=$(echo  "$current_hourly_cost - $hourly_cost" | bc)
             #if (( $(echo "$savings -lt 0" | bc -l )))
             echo "777"
             if (( $(bc <<< "$savings < 0"))); then
               echo "999"
               echo "Instance is not optimized for savings"
             else
               AnnualSavings=$(echo "$savings * 8760" | bc)
               echo "RDS,$instance_id,$current_rds_instance_class,$current_memory_allocated,$current_memory_utilization,$current_hourly_cost,$instance_class,$final_memory_allocated,$suggested_utilization_candidate,$hourly_cost,$savings,$AnnualSavings" >> "$output_file"
             fi
           fi
         fi
      done
    fi
done
echo "Recommendations written to $output_file"
