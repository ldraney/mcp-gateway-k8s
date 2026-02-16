FROM python:3.12.8-slim
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir .
RUN useradd -r -u 1000 -s /bin/false appuser
USER appuser
EXPOSE 8004
CMD ["pal-e-billing"]
