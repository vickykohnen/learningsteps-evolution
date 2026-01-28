import os
import time  # <--- Added this
import logging
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from dotenv import load_dotenv

# Routers
from routers.journal_router import router as journal_router

# Prometheus
from prometheus_client import start_http_server, Counter, Histogram

load_dotenv()

# 1. Initialize Metrics
REQUEST_COUNT = Counter('http_requests_total', 'Total HTTP Requests', ['method', 'endpoint', 'http_status'])
REQUEST_LATENCY = Histogram('http_request_latency_seconds', 'Latency of HTTP requests in seconds', ['endpoint'])

# 2. Define 'app' ONCE
app = FastAPI(
    title="LearningSteps API", 
    description="A simple learning journal API for tracking daily work, struggles, and intentions"
)

# 3. Middleware (Must come before routers)
@app.middleware("http")
async def monitor_requests(request: Request, call_next):
    start_time = time.time()
    endpoint = request.url.path
    method = request.method
    
    response = await call_next(request)
    
    process_time = time.time() - start_time
    status_code = str(response.status_code)
    
    REQUEST_COUNT.labels(method=method, endpoint=endpoint, http_status=status_code).inc()
    REQUEST_LATENCY.labels(endpoint=endpoint).observe(process_time)
    
    return response

# 4. Exception Handlers
@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    print(f"DEBUG: Validation Error: {exc.errors()}", flush=True)
    return JSONResponse(
        status_code=400,
        content={"detail": exc.errors()}
    )

# 5. Routers
app.include_router(journal_router)

# Logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)
logger.info("LearningSteps API started successfully")

# 6. Start Prometheus Metrics Server
metrics_port = int(os.environ.get("METRICS_PORT", 8000))
start_http_server(metrics_port)
print(f"Prometheus metrics available on port {metrics_port}")