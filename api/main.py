# import os
import time  # <--- Added this
import logging
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from dotenv import load_dotenv

# Routers
from routers.journal_router import router as journal_router

# Prometheus
from prometheus_client import make_asgi_app, Counter, Histogram

load_dotenv()

# 1. Initialize Metrics

# Create your custom metrics
REQUEST_COUNT = Counter(
    'api_requests_total',
    'Total API requests',
    ['method', 'endpoint', 'status']
)

REQUEST_DURATION = Histogram(
    'api_request_duration_seconds',
    'API request duration in seconds',
    ['method', 'endpoint']
)

# 2. Define 'app' ONCE
app = FastAPI(
    title="LearningSteps API", 
    description="A simple learning journal API for tracking daily work, struggles, and intentions"
)

@app.get("/")
async def root():
    return {"status": "ok", "message": "LearningSteps API is running"}

# 3. Middleware (Must come before routers)
@app.middleware("http")
async def prometheus_middleware(request: Request, call_next):
    method = request.method
    path = request.url.path
    
    start_time = time.time()
    
    try:
        response = await call_next(request)
        status = response.status_code
    except Exception as e:
        status = 500
        raise e
    finally:
        duration = time.time() - start_time
        REQUEST_DURATION.labels(method=method, endpoint=path).observe(duration)
        REQUEST_COUNT.labels(method=method, endpoint=path, status=status).inc()
    
    return response

# Mount the Prometheus metrics endpoint at /metrics
metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)

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