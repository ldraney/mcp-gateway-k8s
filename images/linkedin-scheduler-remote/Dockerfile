FROM python:3.12-slim
RUN pip install --no-cache-dir linkedin-scheduler-remote-ldraney
EXPOSE 8003
CMD ["python", "-c", "from server import main; main()"]
