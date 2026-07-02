kubectl --context "$CONTEXT" create secret generic openai-secret -n agentgateway-system \
--from-literal="Authorization=Bearer $OPENAI_API_KEY" \
--dry-run=client -oyaml | kubectl --context "$CONTEXT" apply -f -

kubectl --context "$CONTEXT" create secret generic anthropic-secret -n agentgateway-system \
--from-literal="Authorization=$CLAUDE_API_KEY" \
--dry-run=client -oyaml | kubectl --context "$CONTEXT" apply -f -
