# Use an official Python runtime as a parent image
FROM python:3.11-slim

# Add this line to pull the latest security patches
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

# Install the prometheus client library
RUN pip install prometheus-client

# Set the working directory in the container
WORKDIR /app

# Install system dependencies (needed for some python packages)
RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy the requirements file into the container
COPY requirements.txt .

# FIX: Upgrade specific packages to resolve Trivy HIGH/CRITICAL vulnerabilities
# jaraco.context >= 6.1.0 and wheel >= 0.46.2
RUN pip install --no-cache-dir --upgrade pip setuptools \
    && pip install --no-cache-dir "jaraco.context>=6.1.0" "wheel>=0.46.2"

# Install any needed packages specified in requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application code
COPY . .

# Expose the port FastAPI will run on
EXPOSE 8000

# Command to run the application using Uvicorn
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
