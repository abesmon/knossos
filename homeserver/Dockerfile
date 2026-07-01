FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py ./
COPY templates ./templates

ENV HOST=0.0.0.0
ENV PORT=8080
EXPOSE 8080
VOLUME /app/data

CMD ["python", "server.py"]
