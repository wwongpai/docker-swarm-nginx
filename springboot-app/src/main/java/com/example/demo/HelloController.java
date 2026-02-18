package com.example.demo;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {
  private static final Logger logger = LoggerFactory.getLogger(HelloController.class);

  @GetMapping("/")
  public String root() {
    logger.info("Spring Boot root endpoint called");
    return "springboot-nginx-demo ok";
  }

  @GetMapping("/work")
  public String work() throws InterruptedException {
    logger.info("Spring Boot work endpoint called");
    Thread.sleep(100);
    return "springboot-nginx-demo work done";
  }
}
