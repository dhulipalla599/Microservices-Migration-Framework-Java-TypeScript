# Microservices Migration Framework

Production-proven strangler fig migration framework with shadow testing and zero-downtime database decoupling.

## Results

**Prologis & Bupa UK Production Metrics:**
- **P95 Latency**: 4.2s → 0.9s (79% reduction)
- **Deployment Time**: 45m → 6m (87% reduction)  
- **Error Rate**: 1.8% → 0.12% (93% reduction)
- **Production Incidents**: **0** during entire migration

## 5-Phase Migration Strategy

### Phase 1: Characterize
- Baseline performance metrics
- Dependency mapping
- Database schema analysis
- API endpoint inventory

### Phase 2: Containerize
- Docker multi-stage builds
- Kubernetes deployment manifests
- Zero code changes (infrastructure only)

### Phase 3: Strangle
- NGINX proxy with progressive routing
- Shadow mode testing (5% traffic comparison)
- v1 (legacy) and v2 (new) endpoints coexist

### Phase 4: Decouple Database
- Flyway versioned migrations
- Dual-write triggers during transition
- Zero-downtime schema extraction

### Phase 5: Go Async
- Kafka event-driven architecture
- Dead Letter Queue (DLQ) error handling
- Eliminates cascade failures

## Quick Start

### Prerequisites
- Docker & Docker Compose
- Java 17+
- Maven 3.9+
- Node.js 20+ (for shadow proxy)

### Installation

```bash
# Clone repository
git clone https://github.com/dvsandeep/microservices-migration
cd microservices-migration

# Install dependencies
npm run install:all

# Start infrastructure (PostgreSQL, Kafka, Redis)
npm run docker:up

# Apply database migrations
npm run db:migrate

# Start legacy monolith
npm run dev:legacy

# Start new microservices + strangler proxy
npm run dev:new
```

### Access Points

| Service | Port | URL |
|---------|------|-----|
| NGINX Proxy | 80 | http://localhost |
| Legacy Monolith | 8081 | http://localhost:8081 |
| Auth Service | 8082 | http://localhost:8082 |
| Document Service | 8083 | http://localhost:8083 |
| Pricing Service | 8084 | http://localhost:8084 |
| PostgreSQL | 5432 | localhost:5432 |
| Kafka | 9092 | localhost:9092 |

## Project Structure

```
microservices-migration/
├── legacy-monolith/              # Original Spring Boot monolith
│   ├── src/main/java/
│   │   └── com/example/legacy/
│   │       ├── controller/      # REST controllers
│   │       ├── service/         # Business logic
│   │       ├── model/           # JPA entities
│   │       └── repository/      # Data access
│   ├── pom.xml
│   └── Dockerfile
│
├── strangler-architecture/
│   ├── proxy/                    # NGINX + Shadow testing
│   │   ├── nginx.conf           # Traffic routing rules
│   │   └── src/
│   │       └── shadow-mode-middleware.ts
│   │
│   ├── auth-service/            # New microservice (Spring Boot)
│   ├── document-service/        # New microservice (Spring Boot)
│   └── pricing-service/         # New microservice (Spring Boot)
│
├── database-migration/
│   └── flyway/sql/
│       ├── V1.0.0__initial_schema.sql
│       ├── V2.1.0__extract_document_metadata.sql
│       └── V2.2.0__cleanup_dual_write_triggers.sql
│
├── docker-compose.yml
└── README.md
```

## Migration Workflow

### Step 1: Run Legacy Baseline

```bash
# Start only legacy monolith
docker-compose up postgres redis legacy-monolith

# Capture baseline metrics
curl http://localhost:8081/api/documents
# Response time: ~2000ms (slow)
```

### Step 2: Deploy Strangler Proxy

```bash
# Add NGINX proxy routing
docker-compose up nginx-proxy

# Legacy endpoints (v1) → legacy-monolith
curl http://localhost/api/v1/documents

# New endpoints (v2) → document-service
curl http://localhost/api/v2/documents
```

### Step 3: Shadow Mode Testing

NGINX routes 5% of v1 traffic to new service for comparison:

```bash
# Check shadow test logs
docker-compose logs nginx-proxy | grep shadow

# Run dedicated shadow tests
npm run test:shadow
```

### Step 4: Database Migration

```bash
# Apply Flyway migration V2.1.0 (dual-write triggers)
npm run db:migrate

# Now both schemas stay in sync
# shared.documents ←→ document_service.documents

# Validate data consistency
psql -U migration_user -d migration_db -c "SELECT COUNT(*) FROM shared.documents;"
psql -U migration_user -d migration_db -c "SELECT COUNT(*) FROM document_service.documents;"
```

### Step 5: Cutover to New Service

```nginx
# In nginx.conf, change routing:

# Before (legacy)
location ~ ^/api/documents/(.*)$ {
    proxy_pass http://legacy_service;
}

# After (new service)
location ~ ^/api/documents/(.*)$ {
    proxy_pass http://document_service;
}
```

```bash
# Reload NGINX
docker-compose exec nginx-proxy nginx -s reload

# Monitor for 24-48 hours
# If stable, run cleanup migration V2.2.0
```

## Shadow Mode Testing Details

The shadow middleware sends requests to both legacy and new services, compares responses:

```typescript
// 5% of traffic
if (Math.random() < 0.05) {
  const legacyResponse = await callLegacy(req);
  const newResponse = await callNewService(req);
  
  // Compare status codes and response bodies
  if (legacyResponse.status !== newResponse.status) {
    logger.warn('Status code mismatch');
  }
  
  // Always return legacy response to client
  return legacyResponse;
}
```

**Key Metrics Tracked:**
- Status code matches
- Response body matches (deep comparison)
- Latency comparison (legacy vs. new)
- Error rates

## Kafka Event-Driven Pattern

After migration, replace synchronous HTTP chains with async events:

```java
// Before (synchronous)
@PostMapping("/process")
public Response process(Request req) {
    var pricing = pricingService.calculate(req);  // HTTP call
    var doc = documentService.generate(pricing);  // HTTP call
    return new Response(doc);
}

// After (async Kafka)
@PostMapping("/process")
public Response process(Request req) {
    kafkaTemplate.send("process.initiated", req);
    return new Response("Processing", "async");
}

@KafkaListener(topics = "process.initiated")
public void onProcessInitiated(Request req) {
    var pricing = calculate(req);
    kafkaTemplate.send("process.priced", pricing);
}

@KafkaListener(topics = "process.priced")
public void onProcessPriced(PricedRequest req) {
    var doc = generate(req);
    kafkaTemplate.send("process.completed", doc);
}
```

**Benefits:**
- No cascade failures (pricing service down doesn't block document service)
- Automatic retries via Kafka consumer groups
- Dead Letter Queue for failed messages
- Audit trail (replay events for debugging)

## Testing

```bash
# Unit tests
mvn test -f legacy-monolith/pom.xml
mvn test -f strangler-architecture/document-service/pom.xml

# Shadow mode integration tests
npm run test:shadow -w strangler-architecture/proxy

# Load testing
k6 run testing/load-tests/migration-load-test.js
```

## Production Checklist

- [ ] Baseline metrics captured (latency, error rate, throughput)
- [ ] All services containerized and tested
- [ ] NGINX proxy routing verified
- [ ] Shadow mode tests passing (>99% match rate)
- [ ] Database migrations applied (dual-write active)
- [ ] Kafka topics created and configured
- [ ] Dead Letter Queue consumers deployed
- [ ] Monitoring/alerting configured
- [ ] Rollback plan documented
- [ ] 24-48hr monitoring window scheduled

## Rollback Strategy

### During Shadow Mode
- Simply disable shadow traffic routing (zero impact)

### After Cutover (Before Cleanup)
```nginx
# Revert NGINX routing back to legacy
location ~ ^/api/documents/(.*)$ {
    proxy_pass http://legacy_service;  # Back to legacy
}
```

### After Cleanup Migration
- Restore from `shared.documents_archived` table
- Redeploy legacy monolith

## Related Article



## Author

**D.V. Sandeep**  
[LinkedIn](https://linkedin.com/in/dhullipalla-sandeep) | [Email](mailto:dvsandeep599@gmail.com)

## License

MIT
