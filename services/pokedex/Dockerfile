FROM python:3.12-slim
WORKDIR /app
RUN mkdir -p /data
COPY pokedex.py ./
EXPOSE 5005
CMD ["python", "pokedex.py"]
