FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir notion-mcp-remote-ldraney==0.1.0 uvicorn==0.40.0
COPY server.py client_patch.py ./
COPY auth/ ./auth/
EXPOSE 8000
CMD ["python", "server.py"]
