# Lokalny OCR dla skanów (Tesseract, polski + angielski). Bez portów i bez internetu – patrz docker-compose.yml.
FROM python:3.12-slim-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-pol poppler-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY serwer.py .

# bez uprawnień administratora w kontenerze
USER nobody
EXPOSE 8080
CMD ["python", "-u", "serwer.py"]
