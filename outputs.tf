output "ip_backend" { value = aws_instance.backend.public_ip }
output "ip_frontend" { value = aws_eip.frontend.public_ip }
output "backend_id" { value = aws_instance.backend.id }
output "frontend_id" { value = aws_instance.frontend.id }
output "url_sistema" { value = "https://${aws_cloudfront_distribution.cdn.domain_name}" }
output "url_health" { value = "https://${aws_cloudfront_distribution.cdn.domain_name}/api/health" }
