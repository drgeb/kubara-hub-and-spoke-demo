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
