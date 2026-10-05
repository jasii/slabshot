FROM python:3.13-slim
WORKDIR /app
COPY master.py .
RUN useradd -r -u 10001 master
USER master
ENV MASTER_PORT=27580
EXPOSE 27580/tcp
HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request,os;urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"MASTER_PORT\"]}/health',timeout=2)"
CMD ["python", "-u", "master.py"]
