FROM python:3.12-slim

WORKDIR /app

# Copy only what's needed — no requirements.txt since stdlib-only
COPY main.py .

# Run as non-root
RUN useradd -r -u 1001 appuser
USER appuser

EXPOSE 8080

CMD ["python", "main.py"]
