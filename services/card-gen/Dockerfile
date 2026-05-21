FROM python:3.12-slim
WORKDIR /app
COPY generate.py app.py ./
RUN python generate.py
EXPOSE 5000
CMD ["python", "app.py"]
