param(
    [string]$Namespace = "litellm-demo"
)

$ip = kubectl get svc litellm -n $Namespace -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
if (-not $ip) {
    $hostname = kubectl get svc litellm -n $Namespace -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
    if ($hostname) {
        "http://$hostname"
        exit 0
    }
    throw "LiteLLM service does not have an external endpoint yet."
}

"http://$ip"

