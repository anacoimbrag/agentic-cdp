FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY common ./common
COPY training ./training
COPY export_to_serving_store.py .
CMD ["python", "training/segmentation/train_kmeans.py"]
