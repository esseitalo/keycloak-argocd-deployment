FROM quay.io/keycloak/keycloak:latest

ENV KC_DB=postgres
ENV KC_Features=token-exchange

RUN /opt/keycloak/bin/kc.sh build
