FROM python:3.12-alpine

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN adduser -D -u 10001 enricher

WORKDIR /app
COPY enricher.py /app/enricher.py

USER enricher
EXPOSE 8090

CMD ["python3", "/app/enricher.py"]
