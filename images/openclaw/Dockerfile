FROM openclaw:latest

USER root

# Install openclaw-mcp-bridge plugin
COPY openclaw-mcp-bridge /home/node/.openclaw/extensions/openclaw-mcp-bridge

# Rebuild native modules for this Node version and fix permissions
RUN cd /home/node/.openclaw/extensions/openclaw-mcp-bridge && npm rebuild && \
    chown -R node:node /home/node/.openclaw

USER node
