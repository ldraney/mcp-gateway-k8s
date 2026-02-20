FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir notion-mcp-remote-ldraney mcp-remote-auth-ldraney uvicorn
COPY server.py client_patch.py ./
EXPOSE 8000
CMD ["python", "server.py"]
