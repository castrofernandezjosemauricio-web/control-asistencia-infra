"""Test 3 de 3: cifrado en reposo, IMDSv2 y HTTPS para visitantes."""


def test_cifrado_metadata_y_https(resources):
    instances = [
        (name, resource.get("Properties", {}))
        for _, name, resource in resources
        if resource["Type"] == "AWS::EC2::Instance"
    ]
    assert instances, "No hay instancias EC2"
    for name, properties in instances:
        devices = properties.get("BlockDeviceMappings") or []
        assert devices, f"{name}: sin BlockDeviceMappings explicito"
        for device in devices:
            assert device["Ebs"].get("Encrypted") is True, f"{name}: disco sin cifrar"
        metadata = properties.get("MetadataOptions") or {}
        assert metadata.get("HttpTokens") == "required", f"{name}: IMDSv2 no obligatorio"

    distributions = [
        resource.get("Properties", {})
        for _, _, resource in resources
        if resource["Type"] == "AWS::CloudFront::Distribution"
    ]
    assert distributions, "No hay distribucion CloudFront"
    for properties in distributions:
        config = properties["DistributionConfig"]
        behaviors = [config["DefaultCacheBehavior"]] + config.get("CacheBehaviors", [])
        for behavior in behaviors:
            assert behavior["ViewerProtocolPolicy"] in ("redirect-to-https", "https-only"), (
                "CloudFront permite HTTP al visitante"
            )
