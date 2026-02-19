FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir gcal-mcp-remote-ldraney uvicorn
COPY server.py ./
COPY auth/ ./auth/
EXPOSE 8001
CMD ["python", "server.py"]
