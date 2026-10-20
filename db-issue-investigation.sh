echo "Checking for database secrets..."
kubectl -n openproject get secrets

echo "\nInspecting deployment configuration..."
kubectl -n openproject describe deployment openproject-web | less
kubectl -n openproject get deployment openproject-web -o yaml | grep -i env

echo "\nViewing container logs for failed pod..."
kubectl -n openproject logs openproject-web-5d764996c9-jzkvj --container wait-for-db

echo "\nChecking Argo CD sync status..."
argocd app list
argocd app sync-status openproject-spoke


kubectl cluster-info 2>&1 | head -30; echo "---CONTEXTS---"; kubectl config get-contexts 2>&1
 kubectl get ns 2>&1; echo "---ARGOCD NS---"; kubectl get all -n argocd 2>&1 | head -50
 kubectl get pods -A 2>&1 | head -50
 kubectl logs -n argocd deploy/argocd-server --tail=30 2>&1; echo "---TRAEFIK LOGS---"; kubectl logs -n traefik deploy/traefik --tail=50 2>&1
 kubectl get svc -n traefik; echo "---"; kubectl get ingress -n argocd -o yaml

curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" --resolve 172.19.0.5.traefik.me:80:127.0.0.1 http://172.19.0.5.traefik.me/argocd/ -m 10 2>&1; curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" -H "Host: 172.19.0.5.traefik.me" http://127.0.0.1:80/argocd/ -m 10 2>&1


 kubectl get node -o wide 2>&1; echo "---PORTS---"; docker ps --format '{{.Names}} {{.Ports}}' 2>&1 | head -10



 uv add "langchain-openrouter"
