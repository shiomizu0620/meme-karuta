FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY generate.py app.py loader.py ./
COPY data/ ./data/
RUN python generate.py
EXPOSE 5000
CMD ["python", "app.py"]
