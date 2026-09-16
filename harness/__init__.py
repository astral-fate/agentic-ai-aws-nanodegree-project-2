"""
Offline harness for the customer support agent.

Lets ``project/starter/main.py`` run unmodified with no AWS account, by
registering stand-ins for the AgentCore and Strands SDKs in ``sys.modules``
before the deliverable is imported.

    from harness.fakes import load_agent_module
    main = load_agent_module()
    reply = asyncio.run(main.invoke({"prompt": "...", "customer_id": "CUST-123"}))

Read ``harness/fakes.py`` for what is real and what is faked — the short
version is that the Lambda handlers and the discount arithmetic really run,
and the language model does not exist.
"""

__all__ = ["fakes", "gateway", "kb_index", "memory_store", "scripted_model"]
