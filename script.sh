#!/bin/bash

# Function to fetch available EC2 instance types
fetch_available_ec2_instance_types() {
    aws ec2 describe-instance-types --query 'InstanceTypes[*].InstanceType' --output json | jq -r '.[]'
}

# Function to fetch available RDS instance classes
fetch_available_rds_instance_classes() {
    aws rds describe-orderable-db-instance-options --query 'OrderableDBInstanceOptions[*].DBInstanceClass' --output json | jq -r '.[]'
}

# Function to fetch available Elasticache node types
fetch_available_elasticache_node_types() {
    aws elasticache describe-cache-engine-versions --query 'CacheEngineVersions[].CacheParameterGroupFamily' --output json | jq -r '.[]'
}

# Function to fetch hourly on-demand cost for an EC2 instance type
fetch_ec2_instance_type_cost() {
    local instance_type=$1
    aws pricing get-products \
        --service-code AmazonEC2 \
        --filters 'Type=TERM_MATCH,Field=instanceType,Value='"$instance_type" \
        --query 'PriceList[0].terms.OnDemand.*.priceDimensions.*.pricePerUnit.USD' \
        --output json | jq -r '.'
}

# Function to fetch hourly on-demand cost for an RDS instance class
fetch_rds_instance_class_cost() {
    local instance_class=$1
    aws pricing get-products \
        --service-code AmazonRDS \
        --filters 'Type=TERM_MATCH,Field=instanceClass,Value='"$instance_class" \
        --query 'PriceList[0].terms.OnDemand.*.priceDimensions.*.pricePerUnit.USD' \
        --output json | jq -r '.'
}

# Function to fetch hourly on-demand cost for an Elasticache node type
fetch_elasticache_node_type_cost() {
    local node_type=$1
    aws pricing get-products \
        --service-code AmazonElastiCache \
        --filters 'Type=TERM_MATCH,Field=cacheNodeType,Value='"$node_type" \
        --query 'PriceList[0].terms.OnDemand.*.priceDimensions.*.pricePerUnit.USD' \
        --output json | jq -r '.'
}

# Function to fetch CloudWatch metric statistics
fetch_cloudwatch_metric() {
    local resource_id=$1
    local metric_name=$2
    local namespace=$3

    local start_time=$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%SZ')
    local end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    aws cloudwatch get-metric-statistics \
        --namespace "$namespace" \
        --metric-name "$metric_name" \
        --dimensions "Name=InstanceId,Value=$resource_id" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --period 86400 \
        --statistics Average \
        --output json | jq -r '.Datapoints | sort_by(.Timestamp) | last(.[]).Average'
}

# Function to calculate percentage utilization
calculate_percentage_utilization() {
    local current_value=$1
    local total_value=$2

    if [ $total_value -eq 0 ]; then
        echo 0
    else
        echo "scale=2; ($current_value / $total_value) * 100" | bc
    fi
}

# Function to suggest instance type based on utilization and cost
suggest_instance_type() {
    local current_utilization=$1
    local threshold_utilization=$2
    local available_instance_types=("${@:3}")

    local suggested_instance_type=""
    local lowest_cost_instance_type=""
    local lowest_cost=999999999  # Set an initial high value

    for instance_type in "${available_instance_types[@]}"; do
        suggested_utilization_candidate=$(calculate_expected_final_utilization "$current_utilization" "$instance_type")
        
        # Fetch hourly on-demand cost
        hourly_cost=$(fetch_ec2_instance_type_cost "$instance_type")

        if (( $(echo "$suggested_utilization_candidate < $threshold_utilization" | bc -l) )) && (( $(echo "$hourly_cost < $lowest_cost" | bc -l) )); then
            lowest_cost_instance_type=$instance_type
            lowest_cost=$hourly_cost
        fi
    done

    if [ -n "$lowest_cost_instance_type" ]; then
        suggested_instance_type=$lowest_cost_instance_type
    fi

    echo "$suggested_instance_type"
}

# Function to calculate expected final utilization after resizing
calculate_expected_final_utilization() {
    local current_utilization=$1
    local new_instance_type=$2

    # You would need to customize this logic based on how the new instance type affects utilization
    # For simplicity, let's assume a linear relationship for demonstration purposes
    local utilization_factor=0.8  # Adjust this factor based on your specific scenario

    echo "scale=2; $current_utilization * $utilization_factor" | bc
}

# Output file
output_file="recommendations.csv"

# Fetch existing EC2 instances
ec2_instance_ids=($(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output json | jq -r '.[][] | select(.InstanceId != null) | .InstanceId'))

# Fetch existing RDS instances
rds_instance_ids=($(aws rds describe-db-instances --query 'DBInstances[*].DBInstanceIdentifier' --output json | jq -r '.[]'))

# Fetch existing Elasticache clusters
elasticache_cluster_ids=($(aws elasticache describe-cache-clusters --query 'CacheClusters[*].CacheClusterId' --output json | jq -r '.[]'))

# Fetch available EC2 instance types
ec2_available_instance_types=($(fetch_available_ec2_instance_types))

# Fetch available RDS instance classes
rds_available_instance_classes=($(fetch_available_rds_instance_classes))

# Fetch available Elasticache node types
elasticache_available_node_types=($(fetch_available_elasticache_node_types))

# Create CSV file and write header
echo "Resource,Current Utilization,Recommended Instance Type,Expected Final Utilization,Hourly Cost (USD)" > "$output_file"

# EC2 Recommendations
for instance_id in "${ec2_instance_ids[@]}"; do
    current_memory_utilization=$(fetch_cloudwatch_metric "$instance_id" "MemoryUtilization" "System/Linux")
    suggested_ec2_instance_type=$(suggest_instance_type "$current_memory_utilization" 60 "${ec2_available_instance_types[@]}")
    expected_final_ec2_utilization=$(calculate_expected_final_utilization "$current_memory_utilization" "$suggested_ec2_instance_type")

    echo "EC2 Recommendation:"
    echo "Current Memory Utilization: $current_memory_utilization%"
    echo "Suggested Instance Type: $suggested_ec2_instance_type"
    echo "Expected Final Memory Utilization: $expected_final_ec2_utilization%"
    echo "Hourly Cost: $(fetch_ec2_instance_type_cost "$suggested_ec2_instance_type") USD"
    echo

    echo "EC2,$current_memory_utilization,$suggested_ec2_instance_type,$expected_final_ec2_utilization,$(fetch_ec2_instance_type_cost "$suggested_ec2_instance_type")" >> "$output_file"
done

# RDS Recommendations
for instance_id in "${rds_instance_ids[@]}"; do
    current_memory_utilization=$(fetch_cloudwatch_metric "$instance_id" "MemoryUtilization" "AWS/RDS")
    available_instance_classes=("${rds_available_instance_classes[@]}")
    
    lowest_cost_instance_class=""
    lowest_cost=999999999  # Set an initial high value

    for instance_class in "${available_instance_classes[@]}"; do
        suggested_utilization_candidate=$(calculate_expected_final_utilization "$current_memory_utilization" "$instance_class")
        
        # Fetch hourly on-demand cost
        hourly_cost=$(fetch_rds_instance_class_cost "$instance_class")

        if (( $(echo "$suggested_utilization_candidate < 60" | bc -l) )) && (( $(echo "$hourly_cost < $lowest_cost" | bc -l) )); then
            lowest_cost_instance_class=$instance_class
            lowest_cost=$hourly_cost
        fi
    done

    echo "RDS Recommendation:"
    echo "Current Memory Utilization: $current_memory_utilization%"
    echo "Suggested Instance Class: $lowest_cost_instance_class"
    echo "Expected Final Memory Utilization: 60%"  # Assuming target utilization is 60%
    echo "Hourly Cost: $lowest_cost USD"
    echo

    echo "RDS,$current_memory_utilization,$lowest_cost_instance_class,60,$lowest_cost" >> "$output_file"
done

# Elasticache Recommendations
for cluster_id in "${elasticache_cluster_ids[@]}"; do
    current_memory_utilization=$(fetch_cloudwatch_metric "$cluster_id" "MemoryUtilization" "AWS/ElastiCache")
    available_node_types=("${elasticache_available_node_types[@]}")

    lowest_cost_node_type=""
    lowest_cost=999999999  # Set an initial high value

    for node_type in "${available_node_types[@]}"; do
        suggested_utilization_candidate=$(calculate_expected_final_utilization "$current_memory_utilization" "$node_type")
        
        # Fetch hourly on-demand cost
        hourly_cost=$(fetch_elasticache_node_type_cost "$node_type")

        if (( $(echo "$suggested_utilization_candidate < 60" | bc -l) )) && (( $(echo "$hourly_cost < $lowest_cost" | bc -l) )); then
            lowest_cost_node_type=$node_type
            lowest_cost=$hourly_cost
        fi
    done

    echo "Elasticache Recommendation:"
    echo "Current Memory Utilization: $current_memory_utilization%"
    echo "Suggested Node Type: $lowest_cost_node_type"
    echo "Expected Final Memory Utilization: 60%"  # Assuming target utilization is 60%
    echo "Hourly Cost: $lowest_cost USD"
    echo

    echo "Elasticache,$current_memory_utilization,$lowest_cost_node_type,60,$lowest_cost" >> "$output_file"
done

echo "Recommendations written to $output_file"
