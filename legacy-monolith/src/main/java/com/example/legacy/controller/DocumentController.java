package com.example.legacy.controller;

import com.example.legacy.model.Document;
import com.example.legacy.service.DocumentService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/documents")
public class DocumentController {

    @Autowired
    private DocumentService documentService;

    @GetMapping
    public ResponseEntity<List<Document>> listDocuments() {
        return ResponseEntity.ok(documentService.findAll());
    }

    @GetMapping("/{id}")
    public ResponseEntity<Document> getDocument(@PathVariable UUID id) {
        return documentService.findById(id)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    @PostMapping
    public ResponseEntity<Document> createDocument(@RequestBody Document document) {
        Document created = documentService.create(document);
        return ResponseEntity.ok(created);
    }

    @PostMapping("/generate")
    public ResponseEntity<Document> generateDocument(@RequestBody GenerateRequest request) {
        // Simulate slow legacy processing
        try {
            Thread.sleep(2000); // 2 second delay
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        
        Document doc = new Document();
        doc.setTitle(request.getTitle());
        doc.setContentType("application/pdf");
        doc.setFileSize(1024L);
        doc.setStoragePath("/legacy/path/" + UUID.randomUUID());
        doc.setStatus("active");
        
        return ResponseEntity.ok(documentService.create(doc));
    }

    public static class GenerateRequest {
        private String title;
        private String template;

        public String getTitle() { return title; }
        public void setTitle(String title) { this.title = title; }
        public String getTemplate() { return template; }
        public void setTemplate(String template) { this.template = template; }
    }
}
