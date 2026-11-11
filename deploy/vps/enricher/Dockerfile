FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN useradd -r -u 10001 -s /sbin/nologin nonroot

WORKDIR /app
COPY enricher.py /app/enricher.py

USER 10001:10001
EXPOSE 8090

CMD ["python3", "/app/enricher.py"]
