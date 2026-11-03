FROM nginx:alpine
# copied as a template: the nginx image fills in ${UI_API_KEY} from the environment at start-up
COPY default.conf /etc/nginx/templates/default.conf.template
COPY index.html styles.css app.js /usr/share/nginx/html/
EXPOSE 80
