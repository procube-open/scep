import {
  fetchUtils,
  GetListParams,
  GetOneParams,
} from 'react-admin';

const fetchJson = (url: string, options: any) => fetchUtils.fetchJson(url, options)
export const baseDataProvider = {
  getList: (resource: string, params: any): any => Promise,
  getOne: (resource: string, params: any): any => Promise,
  getMany: (resource: string, params: any): any => Promise,
  getManyReference: (resource: string, params: any): any => Promise,
  create: (resource: string, params: any): any => Promise,
  update: (resource: string, params: any): any => Promise,
  updateMany: (resource: string, params: any): any => Promise,
  delete: (resource: string, params: any): any => Promise,
  deleteMany: (resource: string, params: any): any => Promise,
}

export const ClientProvider = {
  ...baseDataProvider,
  getList: async (resource: string, params: GetListParams) => {
    const { page, perPage } = params.pagination;
    const { field, order } = params.sort;
    const { json } = await fetchJson(`/api/${resource}`, {
      method: 'GET',
      headers: new Headers({
        'Content-Type': 'application/json'
      })
    });
    if (!json) return { data: [], total: 0 };
    json.forEach((client: any) => {
      client.id = client.uid;
      client.attributes = JSON.stringify(client.attributes);
    });
    let list = json;
    if (field) list = list.sort((a: any, b: any) => {
      if (a[field] < b[field]) {
        if (order === "ASC") return 1;
        return -1;
      }
      if (a[field] > b[field]) {
        if (order === "ASC") return -1;
        return 1;
      }
      return 0;
    });
    if (page && perPage) list = list.slice((page - 1) * perPage, page * perPage);
    return {
      data: list,
      total: json.length
    };
  },

  getOne: async (resource: string, params: GetOneParams) => {
    const { json } = await fetchJson(`/api/${resource}/${params.id}`, {
      method: 'GET',
      headers: new Headers({
        'Content-Type': 'application/json'
      })
    });
    json.id = json.uid;
    json.attributes = JSON.stringify(json.attributes);
    return { data: json };
  },

  createOne: async (resource: string, params: { uid: string, attributes: string }) => {
    const { uid, attributes } = params;
    const parsed = JSON.parse(attributes);
    if (!parsed) throw new Error("Invalid JSON");
    return fetchJson(`/admin/api/${resource}/add`, {
      method: 'POST',
      headers: new Headers({
        'Content-Type': 'application/json'
      }),
      body: JSON.stringify({
        "uid": uid,
        "attributes": parsed
      })
    });
  },

  revoke: async (resource: string, params: { uid: string }) => {
    const { uid } = params;
    return fetchJson(`/admin/api/${resource}/revoke`, {
      method: 'POST',
      headers: new Headers({
        'Content-Type': 'application/json'
      }),
      body: JSON.stringify({
        "uid": uid
      })
    });
  }
}

export const CertProvider = {
  ...baseDataProvider,
  getList: async (resource: string, params: GetListParams) => {
    const { page, perPage } = params.pagination;
    const { field, order } = params.sort;
    const { json } = await fetchJson(`/api/${resource}/list/${params.meta.cn}`, {
      method: 'GET',
      headers: new Headers({
        'Content-Type': 'application/json'
      })
    });
    if (!json) return { data: [], total: 0 };
    let list = json;
    list.forEach((cert: any) => {
      cert.valid_from = new Date(cert.valid_from)
      cert.valid_till = new Date(cert.valid_till)
      if (cert.revocation_date === "0001-01-01T00:00:00Z")
        cert.revocation_date = null;
      else cert.revocation_date = new Date(cert.revocation_date)
    });
    if (field) list = list.sort((a: any, b: any) => {
      if (a[field] < b[field]) {
        if (order === "ASC") return 1;
        return -1;
      }
      if (a[field] > b[field]) {
        if (order === "ASC") return -1;
        return 1;
      }
      return 0;
    });
    if (page && perPage) list = list.slice((page - 1) * perPage, page * perPage);
    return {
      data: list,
      total: json.length
    };
  },

  pkcs12: async (resource: string, params: { id: string, secret: string, password: string }) => {
    return fetch(`/api/${resource}/pkcs12`, {
      method: 'POST',
      headers: new Headers({
        'Content-Type': 'application/json'
      }),
      body: JSON.stringify({
        "uid": params.id,
        "secret": params.secret,
        "password": params.password
      })
    });
  }
}

export const FilesProvider = {
  ...baseDataProvider,
  getList: async (resource: string, params: GetListParams) => {
    const { page, perPage } = params.pagination;
    const { field, order } = params.sort;
    const { path } = params.meta;
    const urlPath = path.join("/");
    const { json } = await fetchJson(`/api/${urlPath}`, {
      method: 'GET',
      headers: new Headers({
        'Content-Type': 'application/json'
      })
    });
    if (!json) return { data: [], total: 0 };
    json.forEach((file: any) => {
      file.id = file.name;
    });
    let list = json;
    if (field) list = list.sort((a: any, b: any) => {
      if (a[field] < b[field]) {
        if (order === "ASC") return 1;
        return -1;
      }
      if (a[field] > b[field]) {
        if (order === "ASC") return -1;
        return 1;
      }
      return 0;
    });
    if (page && perPage) list = list.slice((page - 1) * perPage, page * perPage);
    return {
      data: list,
      total: json.length
    }
  },
  download: async (resource: string, params: { path: string }) => {
    const { path } = params;
    return fetch(`/api/download${path}`, {
      method: 'GET',
      headers: new Headers({
        'Content-Type': 'application/json'
      })
    });
  },

  getUrl: async (resource: string, params: { path: string }) => {
    const { path } = params;
    const response = await fetch(`/api/download${path}`, {
      method: 'HEAD',
      headers: new Headers({
        'Content-Type': 'application/json'
      })
    })
    return response.url;
  }
}

export const SecretProvider = {
  ...baseDataProvider,
  getSecret: async (resource: string, params: { uid: string }) => {
    const { uid } = params;
    const { json } = await fetchJson(`/admin/api/${resource}/get/${uid}`, {
      method: 'GET',
      headers: new Headers({
        'Content-Type': 'application/json'
      })
    });
    return json;
  },

  createSecret: async (resource: string, params: { target: string, secret: string, delete_at: string, pending_period: string }) => {
    const { target, secret, delete_at, pending_period } = params;

    const now_date = new Date();
    const delete_at_date = delete_at !== null ? new Date(delete_at) : new Date();
    const diff = delete_at_date.getTime() - now_date.getTime();
    const diff_suffix = "ms";

    const pd = pending_period !== "" ? parseInt(pending_period, 10) * 24 : 0;
    const pd_suffix = "h"

    return fetchJson(`/admin/api/${resource}/create`, {
      method: 'POST',
      headers: new Headers({
        'Content-Type': 'application/json'
      }),
      body: JSON.stringify({
        target: target,
        secret: secret,
        available_period: String(diff) + diff_suffix,
        pending_period: String(pd) + pd_suffix
      })
    });
  }
}