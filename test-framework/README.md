```bash
# 1. Install dependencies
npm install

# 2. Build the frontend bundle (Vite). The CDK BucketDeployment uploads
#    src/frontend/dist on deploy, so this step is required.
npm run build

# 3. Deploy to your AWS account (requires CDK bootstrap)
npx cdk deploy \
  --context connectInstanceId=YOUR-CONNECT-INSTANCE-UUID \
  --context adminEmail=you@example.com \
  --context instanceMode=development

# 4. Open the CloudFront URL printed in the stack outputs
#    Sign in with the temporary password emailed to adminEmail.
```
