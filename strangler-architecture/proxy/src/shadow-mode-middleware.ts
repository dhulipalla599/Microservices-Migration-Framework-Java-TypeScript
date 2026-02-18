// shadow-mode-middleware.ts
import { Request, Response, NextFunction } from 'express';
import axios, { AxiosResponse } from 'axios';
import { logger } from './logger';
import { MetricsCollector } from './metrics';

interface ShadowTestResult {
  endpoint: string;
  method: string;
  legacyDuration: number;
  newServiceDuration: number;
  statusMatch: boolean;
  responseMatch: boolean;
  differences?: string[];
  timestamp: number;
}

export class ShadowModeMiddleware {
  private readonly legacyBaseUrl: string;
  private readonly newServiceBaseUrl: string;
  private readonly metrics: MetricsCollector;
  private readonly sampleRate: number; // 0.0 to 1.0

  constructor(
    legacyBaseUrl: string,
    newServiceBaseUrl: string,
    sampleRate = 0.05 // 5% of traffic by default
  ) {
    this.legacyBaseUrl = legacyBaseUrl;
    this.newServiceBaseUrl = newServiceBaseUrl;
    this.metrics = new MetricsCollector();
    this.sampleRate = sampleRate;
  }

  middleware() {
    return async (req: Request, res: Response, next: NextFunction) => {
      // Only shadow test a percentage of requests
      if (Math.random() > this.sampleRate) {
        return next();
      }

      // Don't shadow test mutations in production (too risky)
      if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) {
        logger.warn('Skipping shadow test for mutation', { 
          method: req.method, 
          path: req.path 
        });
        return next();
      }

      try {
        // Call legacy service (this is what we return to the client)
        const legacyStart = Date.now();
        const legacyResponse = await this.callLegacyService(req);
        const legacyDuration = Date.now() - legacyStart;

        // Fire-and-forget call to new service for comparison
        this.compareWithNewService(req, legacyResponse, legacyDuration)
          .catch(err => logger.error('Shadow test comparison failed', { error: err.message }));

        // Return legacy response to client
        res.status(legacyResponse.status).json(legacyResponse.data);

      } catch (error) {
        logger.error('Legacy service call failed', { error });
        return next(error);
      }
    };
  }

  private async callLegacyService(req: Request): Promise<AxiosResponse> {
    return axios({
      method: req.method,
      url: `${this.legacyBaseUrl}${req.path}`,
      params: req.query,
      data: req.body,
      headers: this.sanitizeHeaders(req.headers),
    });
  }

  private async compareWithNewService(
    req: Request,
    legacyResponse: AxiosResponse,
    legacyDuration: number
  ): Promise<void> {
    try {
      const newServiceStart = Date.now();
      const newServiceResponse = await axios({
        method: req.method,
        url: `${this.newServiceBaseUrl}${req.path}`,
        params: req.query,
        data: req.body,
        headers: this.sanitizeHeaders(req.headers),
        timeout: 5000, // Don't let shadow tests hang forever
      });
      const newServiceDuration = Date.now() - newServiceStart;

      const result = this.analyzeResponses(
        req,
        legacyResponse,
        legacyDuration,
        newServiceResponse,
        newServiceDuration
      );

      // Log result
      if (!result.statusMatch || !result.responseMatch) {
        logger.warn('Shadow test mismatch detected', result);
      } else {
        logger.debug('Shadow test passed', {
          endpoint: result.endpoint,
          legacyDuration: result.legacyDuration,
          newServiceDuration: result.newServiceDuration,
        });
      }

      // Record metrics
      this.metrics.recordShadowTest(result);

    } catch (error) {
      logger.error('New service call failed in shadow test', {
        path: req.path,
        error: error instanceof Error ? error.message : 'Unknown error',
      });
    }
  }

  private analyzeResponses(
    req: Request,
    legacyResponse: AxiosResponse,
    legacyDuration: number,
    newServiceResponse: AxiosResponse,
    newServiceDuration: number
  ): ShadowTestResult {
    const statusMatch = legacyResponse.status === newServiceResponse.status;
    
    // Deep compare response bodies
    const { match: responseMatch, differences } = this.deepCompare(
      legacyResponse.data,
      newServiceResponse.data
    );

    return {
      endpoint: req.path,
      method: req.method,
      legacyDuration,
      newServiceDuration,
      statusMatch,
      responseMatch,
      differences: differences.length > 0 ? differences : undefined,
      timestamp: Date.now(),
    };
  }

  private deepCompare(
    obj1: unknown,
    obj2: unknown,
    path = ''
  ): { match: boolean; differences: string[] } {
    const differences: string[] = [];

    // Type mismatch
    if (typeof obj1 !== typeof obj2) {
      differences.push(`${path}: type mismatch (${typeof obj1} vs ${typeof obj2})`);
      return { match: false, differences };
    }

    // Primitive comparison
    if (typeof obj1 !== 'object' || obj1 === null || obj2 === null) {
      if (obj1 !== obj2) {
        differences.push(`${path}: value mismatch (${obj1} vs ${obj2})`);
        return { match: false, differences };
      }
      return { match: true, differences };
    }

    // Array comparison
    if (Array.isArray(obj1) && Array.isArray(obj2)) {
      if (obj1.length !== obj2.length) {
        differences.push(`${path}: array length mismatch (${obj1.length} vs ${obj2.length})`);
      }

      const maxLen = Math.max(obj1.length, obj2.length);
      for (let i = 0; i < maxLen; i++) {
        const result = this.deepCompare(obj1[i], obj2[i], `${path}[${i}]`);
        differences.push(...result.differences);
      }

      return { match: differences.length === 0, differences };
    }

    // Object comparison
    const keys1 = Object.keys(obj1 as object);
    const keys2 = Object.keys(obj2 as object);
    const allKeys = new Set([...keys1, ...keys2]);

    allKeys.forEach(key => {
      const val1 = (obj1 as Record<string, unknown>)[key];
      const val2 = (obj2 as Record<string, unknown>)[key];

      if (val1 === undefined) {
        differences.push(`${path}.${key}: missing in legacy response`);
      } else if (val2 === undefined) {
        differences.push(`${path}.${key}: missing in new service response`);
      } else {
        const result = this.deepCompare(val1, val2, `${path}.${key}`);
        differences.push(...result.differences);
      }
    });

    return { match: differences.length === 0, differences };
  }

  private sanitizeHeaders(headers: Record<string, unknown>): Record<string, string> {
    const sanitized: Record<string, string> = {};
    const allowedHeaders = ['authorization', 'content-type', 'accept', 'user-agent'];

    Object.entries(headers).forEach(([key, value]) => {
      if (allowedHeaders.includes(key.toLowerCase()) && typeof value === 'string') {
        sanitized[key] = value;
      }
    });

    return sanitized;
  }
}
