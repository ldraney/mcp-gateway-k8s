FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir gcal-mcp-remote-ldraney mcp-remote-auth-ldraney uvicorn
COPY server.py ./
EXPOSE 8001
CMD ["python", "server.py"]
